#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <openssl/bio.h>
#include <openssl/bn.h>
#include <openssl/err.h>
#include <openssl/md5.h>
#include <openssl/objects.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include <openssl/ripemd.h>
#include <openssl/rsa.h>
#include <openssl/sha.h>
#include <openssl/ssl.h>

typedef struct
{
    RSA* rsa;
    int padding;
    int hashMode;
} rsaData;

/* Key names for the rsa hash structure */

#define KEY_KEY "_Key"
#define PADDING_KEY "_Padding"
#define HASH_KEY "_Hash_Mode"

#define PACKAGE_NAME "Crypt::OpenSSL::RSA"

void croakSsl(char* p_file, int p_line)
{
    const char* errorReason;
    /* Just return the top error on the stack */
    errorReason = ERR_reason_error_string(ERR_get_error());
    ERR_clear_error();
    croak("%s:%d: OpenSSL error: %s", p_file, p_line, errorReason);
}

#define CHECK_OPEN_SSL(p_result) if (!(p_result)) croakSsl(__FILE__, __LINE__);

#define PACKAGE_CROAK(p_message) croak("%s", (p_message))
#define CHECK_NEW(p_var, p_size, p_type) \
  if (New(0, p_var, p_size, p_type) == NULL) \
    { PACKAGE_CROAK("unable to alloc buffer"); }

#define THROW(p_result) if (!(p_result)) { error = 1; goto err; }

#if OPENSSL_VERSION_NUMBER < 0x10100000 || defined(LIBRESSL_VERSION_NUMBER)

static void RSA_get0_key(const RSA *r,
                         const BIGNUM **n, const BIGNUM **e, const BIGNUM **d)
{
    if (n != NULL)
        *n = r->n;
    if (e != NULL)
        *e = r->e;
    if (d != NULL)
        *d = r->d;
}

static int RSA_set0_key(RSA *r, BIGNUM *n, BIGNUM *e, BIGNUM *d)
{
    /* If the fields n and e in r are NULL, the corresponding input
     * parameters MUST be non-NULL for n and e.  d may be
     * left NULL (in case only the public key is used).
     */
    if ((r->n == NULL && n == NULL)
        || (r->e == NULL && e == NULL))
        return 0;

    if (n != NULL) {
        BN_free(r->n);
        r->n = n;
    }
    if (e != NULL) {
        BN_free(r->e);
        r->e = e;
    }
    if (d != NULL) {
        BN_free(r->d);
        r->d = d;
    }

    return 1;
}

static int RSA_set0_factors(RSA *r, BIGNUM *p, BIGNUM *q)
{
    /* If the fields p and q in r are NULL, the corresponding input
     * parameters MUST be non-NULL.
     */
    if ((r->p == NULL && p == NULL)
        || (r->q == NULL && q == NULL))
        return 0;

    if (p != NULL) {
        BN_free(r->p);
        r->p = p;
    }
    if (q != NULL) {
        BN_free(r->q);
        r->q = q;
    }

    return 1;
}

static void RSA_get0_factors(const RSA *r, const BIGNUM **p, const BIGNUM **q)
{
    if (p != NULL)
        *p = r->p;
    if (q != NULL)
        *q = r->q;
}

static int RSA_set0_crt_params(RSA *r, BIGNUM *dmp1, BIGNUM *dmq1, BIGNUM *iqmp)
{
    /* If the fields dmp1, dmq1 and iqmp in r are NULL, the corresponding input
     * parameters MUST be non-NULL.
     */
    if ((r->dmp1 == NULL && dmp1 == NULL)
        || (r->dmq1 == NULL && dmq1 == NULL)
        || (r->iqmp == NULL && iqmp == NULL))
        return 0;

    if (dmp1 != NULL) {
        BN_free(r->dmp1);
        r->dmp1 = dmp1;
    }
    if (dmq1 != NULL) {
        BN_free(r->dmq1);
        r->dmq1 = dmq1;
    }
    if (iqmp != NULL) {
        BN_free(r->iqmp);
        r->iqmp = iqmp;
    }

    return 1;
}

static void RSA_get0_crt_params(const RSA *r,
                                const BIGNUM **dmp1, const BIGNUM **dmq1,
                                const BIGNUM **iqmp)
{
    if (dmp1 != NULL)
        *dmp1 = r->dmp1;
    if (dmq1 != NULL)
        *dmq1 = r->dmq1;
    if (iqmp != NULL)
        *iqmp = r->iqmp;
}
#endif

char _is_private(rsaData* p_rsa)
{
    const BIGNUM *d;

    RSA_get0_key(p_rsa->rsa, NULL, NULL, &d);
    return(d != NULL);
}

SV* make_rsa_obj(SV* p_proto, RSA* p_rsa)
{
    rsaData* rsa;

    CHECK_NEW(rsa, 1, rsaData);
    rsa->rsa = p_rsa;
    rsa->hashMode = NID_sha1;
    rsa->padding = RSA_PKCS1_OAEP_PADDING;
    return sv_bless(
        newRV_noinc(newSViv((IV) rsa)),
        (SvROK(p_proto) ? SvSTASH(SvRV(p_proto)) : gv_stashsv(p_proto, 1)));
}

int get_digest_length(int hash_method)
{
    switch(hash_method)
    {
        case NID_md5:
            return MD5_DIGEST_LENGTH;
            break;
        case NID_sha1:
            return SHA_DIGEST_LENGTH;
            break;
#ifdef SHA512_DIGEST_LENGTH
        case NID_sha224:
            return SHA224_DIGEST_LENGTH;
            break;
        case NID_sha256:
            return SHA256_DIGEST_LENGTH;
            break;
        case NID_sha384:
            return SHA384_DIGEST_LENGTH;
            break;
        case NID_sha512:
            return SHA512_DIGEST_LENGTH;
            break;
#endif
        case NID_ripemd160:
            return RIPEMD160_DIGEST_LENGTH;
            break;
        default:
            croak("Unknown digest hash code");
            break;
    }
}

unsigned char* get_message_digest(SV* text_SV, int hash_method)
{
    STRLEN text_length;
    unsigned char* text;

    text = (unsigned char*) SvPV(text_SV, text_length);

    switch(hash_method)
    {
        case NID_md5:
            return MD5(text, text_length, NULL);
            break;
        case NID_sha1:
            return SHA1(text, text_length, NULL);
            break;
#ifdef SHA512_DIGEST_LENGTH
        case NID_sha224:
            return SHA224(text, text_length, NULL);
            break;
        case NID_sha256:
            return SHA256(text, text_length, NULL);
            break;
        case NID_sha384:
            return SHA384(text, text_length, NULL);
            break;
        case NID_sha512:
            return SHA512(text, text_length, NULL);
            break;
#endif
        case NID_ripemd160:
            return RIPEMD160(text, text_length, NULL);
            break;
        default:
            croak("Unknown digest hash code");
            break;
    }
}

SV* bn2sv(const BIGNUM* p_bn)
{
    return p_bn != NULL
        ? sv_2mortal(newSViv((IV) BN_dup(p_bn)))
        : &PL_sv_undef;
}

SV* extractBioString(BIO* p_stringBio)
{
    SV* sv;
    BUF_MEM* bptr;

    CHECK_OPEN_SSL(BIO_flush(p_stringBio) == 1);
    BIO_get_mem_ptr(p_stringBio, &bptr);
    sv = newSVpv(bptr->data, bptr->length);

    CHECK_OPEN_SSL(BIO_set_close(p_stringBio, BIO_CLOSE) == 1);
    BIO_free(p_stringBio);
    return sv;
}

RSA* _load_rsa_key(SV* p_keyStringSv,
                   RSA*(*p_loader)(BIO*, RSA**, pem_password_cb*, void*))
{
    STRLEN keyStringLength;
    char* keyString;

    RSA* rsa;
    BIO* stringBIO;

    keyString = SvPV(p_keyStringSv, keyStringLength);

    CHECK_OPEN_SSL(stringBIO = BIO_new_mem_buf(keyString, keyStringLength));

    rsa = p_loader(stringBIO, NULL, NULL, NULL);

    CHECK_OPEN_SSL(BIO_set_close(stringBIO, BIO_CLOSE) == 1);
    BIO_free(stringBIO);

    CHECK_OPEN_SSL(rsa);
    return rsa;
}

SV* rsa_crypt(rsaData* p_rsa, SV* p_from,
              int (*p_crypt)(int, const unsigned char*, unsigned char*, RSA*, int))
{
    STRLEN from_length;
    int to_length;
    int size;
    unsigned char* from;
    char* to;
    SV* sv;

    from = (unsigned char*) SvPV(p_from, from_length);
    size = RSA_size(p_rsa->rsa);
    CHECK_NEW(to, size, char);

    to_length = p_crypt(
       from_length, from, (unsigned char*) to, p_rsa->rsa, p_rsa->padding);

    if (to_length < 0)
    {
        Safefree(to);
        CHECK_OPEN_SSL(0);
    }
    sv = newSVpv(to, to_length);
    Safefree(to);
    return sv;
}


MODULE = Crypt::OpenSSL::RSA		PACKAGE = Crypt::OpenSSL::RSA
PROTOTYPES: DISABLE

BOOT:
    ERR_load_crypto_strings();

SV*
new_private_key(proto, key_string_SV)
    SV* proto;
    SV* key_string_SV;
  CODE:
    RETVAL = make_rsa_obj(
        proto, _load_rsa_key(key_string_SV, PEM_read_bio_RSAPrivateKey));
  OUTPUT:
    RETVAL

SV*
_new_public_key_pkcs1(proto, key_string_SV)
    SV* proto;
    SV* key_string_SV;
  CODE:
    RETVAL = make_rsa_obj(
        proto, _load_rsa_key(key_string_SV, PEM_read_bio_RSAPublicKey));
  OUTPUT:
    RETVAL

SV*
_new_public_key_x509(proto, key_string_SV)
    SV* proto;
    SV* key_string_SV;
  CODE:
    RETVAL = make_rsa_obj(
        proto, _load_rsa_key(key_string_SV, PEM_read_bio_RSA_PUBKEY));
  OUTPUT:
    RETVAL

void
DESTROY(p_rsa)
    rsaData* p_rsa;
  CODE:
    RSA_free(p_rsa->rsa);
    Safefree(p_rsa);

SV*
get_private_key_string(p_rsa)
    rsaData* p_rsa;
  PREINIT:
    BIO* stringBIO;
  CODE:
    CHECK_OPEN_SSL(stringBIO = BIO_new(BIO_s_mem()));
    PEM_write_bio_RSAPrivateKey(
        stringBIO, p_rsa->rsa, NULL, NULL, 0, NULL, NULL);
    RETVAL = extractBioString(stringBIO);

  OUTPUT:
    RETVAL

SV*
get_public_key_string(p_rsa)
    rsaData* p_rsa;
  PREINIT:
    BIO* stringBIO;
  CODE:
    CHECK_OPEN_SSL(stringBIO = BIO_new(BIO_s_mem()));
    PEM_write_bio_RSAPublicKey(stringBIO, p_rsa->rsa);
    RETVAL = extractBioString(stringBIO);

  OUTPUT:
    RETVAL

SV*
get_public_key_x509_string(p_rsa)
    rsaData* p_rsa;
  PREINIT:
    BIO* stringBIO;
  CODE:
    CHECK_OPEN_SSL(stringBIO = BIO_new(BIO_s_mem()));
    PEM_write_bio_RSA_PUBKEY(stringBIO, p_rsa->rsa);
    RETVAL = extractBioString(stringBIO);

  OUTPUT:
    RETVAL

SV*
generate_key(proto, bitsSV, exponent = 65537)
    SV* proto;
    SV* bitsSV;
    unsigned long exponent;
  PREINIT:
    RSA* rsa;
    BIGNUM *e;
  CODE:
    e = BN_new();
    CHECK_OPEN_SSL(e);
    rsa = RSA_new();
    CHECK_OPEN_SSL(rsa);
    BN_set_word(e, exponent);
    CHECK_OPEN_SSL(RSA_generate_key_ex(rsa, SvIV(bitsSV), e, NULL));
    BN_free(e);
    RETVAL = make_rsa_obj(proto, rsa);
  OUTPUT:
    RETVAL


SV*
_new_key_from_parameters(proto, n, e, d, p, q)
    SV* proto;
    BIGNUM* n;
    BIGNUM* e;
    BIGNUM* d;
    BIGNUM* p;
    BIGNUM* q;
  PREINIT:
    RSA* rsa;
    BN_CTX* ctx;
    BIGNUM* p_minus_1 = NULL;
    BIGNUM* q_minus_1 = NULL;
    int error;
  CODE:
{
    if (!(n && e))
    {
        croak("At least a modulous and public key must be provided");
    }
    CHECK_OPEN_SSL(rsa = RSA_new());
    CHECK_OPEN_SSL(RSA_set0_key(rsa, n, e, NULL));
    if (p || q)
    {
        BIGNUM *dmp1, *dmq1, *iqmp;

        error = 0;
        THROW(ctx = BN_CTX_new());
        if (!p)
        {
            THROW(p = BN_new());
            THROW(BN_div(p, NULL, n, q, ctx));
        }
        else if (!q)
        {
            q = BN_new();
            THROW(BN_div(q, NULL, n, p, ctx));
        }
        CHECK_OPEN_SSL(RSA_set0_factors(rsa, p, q));
        THROW(p_minus_1 = BN_new());
        THROW(BN_sub(p_minus_1, p, BN_value_one()));
        THROW(q_minus_1 = BN_new());
        THROW(BN_sub(q_minus_1, q, BN_value_one()));
        if (!d)
        {
            THROW(d = BN_new());
            THROW(BN_mul(d, p_minus_1, q_minus_1, ctx));
            THROW(BN_mod_inverse(d, e, d, ctx));
        }
        CHECK_OPEN_SSL(RSA_set0_key(rsa, NULL, NULL, d));

        THROW(dmp1 = BN_new());
        THROW(dmq1 = BN_new());
        THROW(iqmp = BN_new());

        THROW(BN_mod(dmp1, d, p_minus_1, ctx));
        THROW(BN_mod(dmq1, d, q_minus_1, ctx));
        THROW(BN_mod_inverse(iqmp, q, p, ctx));

        CHECK_OPEN_SSL(RSA_set0_crt_params(rsa, dmp1, dmq1, iqmp));
        THROW(RSA_check_key(rsa) == 1);
     err:
        if (p_minus_1) BN_clear_free(p_minus_1);
        if (q_minus_1) BN_clear_free(q_minus_1);
        if (ctx) BN_CTX_free(ctx);
        if (error)
        {
            RSA_free(rsa);
            CHECK_OPEN_SSL(0);
        }
    }
    else
    {
        CHECK_OPEN_SSL(RSA_set0_key(rsa, NULL, NULL, d));
    }
    RETVAL = make_rsa_obj(proto, rsa);
}
  OUTPUT:
    RETVAL

void
_get_key_parameters(p_rsa)
    rsaData* p_rsa;
PPCODE:
{
    RSA* rsa;
    const BIGNUM *n, *e, *d, *p, *q;
    const BIGNUM *dmp1, *dmq1, *iqmp;

    rsa = p_rsa->rsa;
    RSA_get0_key(rsa, &n, &e, &d);
    RSA_get0_factors(rsa, &p, &q);
    RSA_get0_crt_params(rsa, &dmp1, &dmq1, &iqmp);
    XPUSHs(bn2sv(n));
    XPUSHs(bn2sv(e));
    XPUSHs(bn2sv(d));
    XPUSHs(bn2sv(p));
    XPUSHs(bn2sv(q));
    XPUSHs(bn2sv(dmp1));
    XPUSHs(bn2sv(dmq1));
    XPUSHs(bn2sv(iqmp));
}

SV*
encrypt(p_rsa, p_plaintext)
    rsaData* p_rsa;
    SV* p_plaintext;
  CODE:
    RETVAL = rsa_crypt(p_rsa, p_plaintext, RSA_public_encrypt);
  OUTPUT:
    RETVAL

SV*
decrypt(p_rsa, p_ciphertext)
    rsaData* p_rsa;
    SV* p_ciphertext;
  CODE:
    if (!_is_private(p_rsa))
    {
        croak("Public keys cannot decrypt");
    }
    RETVAL = rsa_crypt(p_rsa, p_ciphertext, RSA_private_decrypt);
  OUTPUT:
    RETVAL

SV*
private_encrypt(p_rsa, p_plaintext)
    rsaData* p_rsa;
    SV* p_plaintext;
  CODE:
    if (!_is_private(p_rsa))
    {
        croak("Public keys cannot private_encrypt");
    }
    RETVAL = rsa_crypt(p_rsa, p_plaintext, RSA_private_encrypt);
  OUTPUT:
    RETVAL

SV*
public_decrypt(p_rsa, p_ciphertext)
    rsaData* p_rsa;
    SV* p_ciphertext;
  CODE:
    RETVAL = rsa_crypt(p_rsa, p_ciphertext, RSA_public_decrypt);
  OUTPUT:
    RETVAL

int
size(p_rsa)
    rsaData* p_rsa;
  CODE:
    RETVAL = RSA_size(p_rsa->rsa);
  OUTPUT:
    RETVAL

int
check_key(p_rsa)
    rsaData* p_rsa;
  CODE:
    if (!_is_private(p_rsa))
    {
        croak("Public keys cannot be checked");
    }
    RETVAL = RSA_check_key(p_rsa->rsa);
  OUTPUT:
    RETVAL

 # Seed the PRNG with user-provided bytes; returns true if the
 # seeding was sufficient.

int
_random_seed(random_bytes_SV)
    SV* random_bytes_SV;
  PREINIT:
    STRLEN random_bytes_length;
    char* random_bytes;
  CODE:
    random_bytes = SvPV(random_bytes_SV, random_bytes_length);
    RAND_seed(random_bytes, random_bytes_length);
    RETVAL = RAND_status();
  OUTPUT:
    RETVAL

 # Returns true if the PRNG has enough seed data

int
_random_status()
  CODE:
    RETVAL = RAND_status();
  OUTPUT:
    RETVAL

void
use_md5_hash(p_rsa)
    rsaData* p_rsa;
  CODE:
    p_rsa->hashMode = NID_md5;

void
use_sha1_hash(p_rsa)
    rsaData* p_rsa;
  CODE:
    p_rsa->hashMode =  NID_sha1;

#ifdef SHA512_DIGEST_LENGTH

void
use_sha224_hash(p_rsa)
    rsaData* p_rsa;
  CODE:
    p_rsa->hashMode =  NID_sha224;

void
use_sha256_hash(p_rsa)
    rsaData* p_rsa;
  CODE:
    p_rsa->hashMode =  NID_sha256;

void
use_sha384_hash(p_rsa)
    rsaData* p_rsa;
  CODE:
    p_rsa->hashMode =  NID_sha384;

void
use_sha512_hash(p_rsa)
    rsaData* p_rsa;
  CODE:
    p_rsa->hashMode =  NID_sha512;

#endif

void
use_ripemd160_hash(p_rsa)
    rsaData* p_rsa;
  CODE:
    p_rsa->hashMode =  NID_ripemd160;

void
use_no_padding(p_rsa)
    rsaData* p_rsa;
  CODE:
    p_rsa->padding = RSA_NO_PADDING;

void
use_pkcs1_padding(p_rsa)
    rsaData* p_rsa;
  CODE:
    p_rsa->padding = RSA_PKCS1_PADDING;

void
use_pkcs1_oaep_padding(p_rsa)
    rsaData* p_rsa;
  CODE:
    p_rsa->padding = RSA_PKCS1_OAEP_PADDING;

void
use_sslv23_padding(p_rsa)
    rsaData* p_rsa;
  CODE:
    p_rsa->padding = RSA_SSLV23_PADDING;

# Sign text. Returns the signature.

SV*
sign(p_rsa, text_SV)
    rsaData* p_rsa;
    SV* text_SV;
  PREINIT:
    char* signature;
    unsigned char* digest;
    unsigned int signature_length;
  CODE:
{
    if (!_is_private(p_rsa))
    {
        croak("Public keys cannot sign messages.");
    }

    CHECK_NEW(signature, RSA_size(p_rsa->rsa), char);

    CHECK_OPEN_SSL(digest = get_message_digest(text_SV, p_rsa->hashMode));
    CHECK_OPEN_SSL(RSA_sign(p_rsa->hashMode,
                            digest,
                            get_digest_length(p_rsa->hashMode),
                            (unsigned char*) signature,
                            &signature_length,
                            p_rsa->rsa));
    RETVAL = newSVpvn(signature, signature_length);
    Safefree(signature);
}
  OUTPUT:
    RETVAL

# Verify signature. Returns true if correct, false otherwise.

void
verify(p_rsa, text_SV, sig_SV)
    rsaData* p_rsa;
    SV* text_SV;
    SV* sig_SV;
PPCODE:
{
    unsigned char* sig;
    unsigned char* digest;
    STRLEN sig_length;

    sig = (unsigned char*) SvPV(sig_SV, sig_length);
    if (RSA_size(p_rsa->rsa) < sig_length)
    {
        croak("Signature longer than key");
    }

    CHECK_OPEN_SSL(digest = get_message_digest(text_SV, p_rsa->hashMode));
    switch(RSA_verify(p_rsa->hashMode,
                      digest,
                      get_digest_length(p_rsa->hashMode),
                      sig,
                      sig_length,
                      p_rsa->rsa))
    {
        case 0:
            CHECK_OPEN_SSL(ERR_peek_error());
            XSRETURN_NO;
            break;
        case 1:
            XSRETURN_YES;
            break;
        default:
            CHECK_OPEN_SSL(0);
            break;
    }
}

int
is_private(p_rsa)
    rsaData* p_rsa;
  CODE:
    RETVAL = _is_private(p_rsa);
  OUTPUT:
    RETVAL
