#include <string.h>
#include <stdlib.h>
#include <openssl/crypto.h>
#include <openssl/pem.h>
#include <openssl/err.h>
#include <openssl/pkcs12.h>
#include <openssl/x509.h>

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

struct crypt_smime {
    EVP_PKEY *priv_key;
    X509* priv_cert;

    const EVP_CIPHER* cipher;

    /* 暗号化, 添付用 */
    STACK_OF(X509)* pubkeys_stack;

    /* 検証用 */
    X509_STORE* pubkeys_store;
};
typedef struct crypt_smime * Crypt_SMIME;

#define OPENSSL_CROAK(description) 				\
    croak("%s: %s",						\
	  description,						\
	  ERR_error_string(ERR_get_error(), NULL))

/* B64_write_PKCS7 is copyed from openssl/crypto/pkcs7/pk7_mime.c */
static int B64_write_PKCS7(BIO *bio, PKCS7 *p7)
{
        BIO *b64;
        if(!(b64 = BIO_new(BIO_f_base64()))) {
                PKCS7err(PKCS7_F_B64_WRITE_PKCS7,ERR_R_MALLOC_FAILURE);
                return 0;
        }
        bio = BIO_push(b64, bio);
        i2d_PKCS7_bio(bio, p7);
        (void)BIO_flush(bio);
        bio = BIO_pop(bio);
        BIO_free(b64);
        return 1;
}


static EVP_PKEY* load_privkey(Crypt_SMIME this, char* pem, char* password) {
    BIO *buf;
    EVP_PKEY *key;

    buf = BIO_new_mem_buf(pem, -1);
    if (buf == NULL) {
        return NULL;
    }

    key = PEM_read_bio_PrivateKey(
	buf, NULL, (pem_password_cb*)NULL, password);
    BIO_free(buf);

    return key;
}

/* ----------------------------------------------------------------------------
 * X509* x509 = load_cert(crt);
 * extract X509 information from cert data.
 * not from file, from just data.
 * ------------------------------------------------------------------------- */
static X509* load_cert(char* crt) {
    BIO* buf;
    X509 *x;

    buf = BIO_new_mem_buf(crt, -1);
    if (buf == NULL) {
	return NULL;
    }

    x = PEM_read_bio_X509_AUX(buf, NULL, NULL, NULL);
    BIO_free(buf);

    return x;
}

static SV* sign(Crypt_SMIME this, char* raw) {
    BIO* inbuf;
    BIO* outbuf;
    PKCS7* pkcs7;
    int flags = PKCS7_DETACHED;
    BUF_MEM* bufmem;
    SV* result;
    int err;

    inbuf = BIO_new_mem_buf(raw, -1);
    if (inbuf == NULL) {
	return NULL;
    }

    /*クリア署名を作る */
    pkcs7 = PKCS7_sign(this->priv_cert, this->priv_key, NULL, inbuf, flags);
    
    if (pkcs7 == NULL) {
	return NULL;
    }

    outbuf = BIO_new(BIO_s_mem());
    if (outbuf == NULL) {
	PKCS7_free(pkcs7);
	return NULL;
    }

    (void)BIO_reset(inbuf);

    {
      int i;
      for( i=0; i< sk_X509_num(this->pubkeys_stack); ++i )
      {
        X509* x509 = sk_X509_value(this->pubkeys_stack,i);
        assert( x509!=NULL );
        PKCS7_add_certificate(pkcs7, x509);
      }
    }
    
    err = SMIME_write_PKCS7(outbuf, pkcs7, inbuf, flags);
    PKCS7_free(pkcs7);
    BIO_free(inbuf);

    if (err != 1) {
	return NULL;
    }

    BIO_get_mem_ptr(outbuf, &bufmem);
    result = newSVpv(bufmem->data, bufmem->length);
    BIO_free(outbuf);

    return result;
}

static SV* signonly(Crypt_SMIME this, char* raw) {
    BIO* inbuf;
    BIO* outbuf;
    PKCS7* pkcs7;
    int flags = PKCS7_DETACHED;
    BUF_MEM* bufmem;
    SV* result;
    int err;

    inbuf = BIO_new_mem_buf(raw, -1);
    if (inbuf == NULL) {
	return NULL;
    }

    /*クリア署名を作る */
    pkcs7 = PKCS7_sign(this->priv_cert, this->priv_key, NULL, inbuf, flags);
    
    BIO_free(inbuf);
    
    if (pkcs7 == NULL) {
	return NULL;
    }

    outbuf = BIO_new(BIO_s_mem());
    if (outbuf == NULL) {
	PKCS7_free(pkcs7);
	return NULL;
    }

    {
      int i;
      for( i=0; i< sk_X509_num(this->pubkeys_stack); ++i )
      {
        X509* x509 = sk_X509_value(this->pubkeys_stack,i);
        assert( x509!=NULL );
        PKCS7_add_certificate(pkcs7, x509);
      }
    }
    
    err = B64_write_PKCS7(outbuf, pkcs7);
    PKCS7_free(pkcs7);

    if (err != 1) {
	return NULL;
    }

    BIO_get_mem_ptr(outbuf, &bufmem);
    result = newSVpv(bufmem->data, bufmem->length);
    BIO_free(outbuf);

    return result;
}

static SV* check(Crypt_SMIME this, char* signed_mime) {
    BIO* inbuf;
    BIO* detached = NULL;
    BIO* outbuf;
    PKCS7* sign;
    int flags = 0;
    int err;
    BUF_MEM* bufmem;
    SV* result;

    inbuf = BIO_new_mem_buf(signed_mime, -1);
    if (inbuf == NULL) {
	return NULL;
    }

    sign = SMIME_read_PKCS7(inbuf, &detached);
    BIO_free(inbuf);
    
    if (sign == NULL) {
	return NULL;
    }

    outbuf = BIO_new(BIO_s_mem());
    if (outbuf == NULL) {
	PKCS7_free(sign);
	return NULL;
    }
    
    // The public certs could be a CA (or self-signed CA cert)
    err = PKCS7_verify(sign, NULL, this->pubkeys_store, detached, outbuf, flags);
    if (err <= 0) {
        ERR_clear_error();
        // ...and could be an end user cert. 
        // And the content might not have the cert embedded.
        err = PKCS7_verify(sign, this->pubkeys_stack, NULL, detached, outbuf, PKCS7_NOINTERN | PKCS7_NOVERIFY);
    }
    PKCS7_free(sign);
    
    if (detached != NULL) {
	BIO_free(detached);
    }

    if (err <= 0) {
	BIO_free(outbuf);
	return NULL;
    }

    BIO_get_mem_ptr(outbuf, &bufmem);
    result = newSVpv(bufmem->data, bufmem->length);
    BIO_free(outbuf);

    return result;
}

static SV* _encrypt(Crypt_SMIME this, char* raw) {
    BIO* inbuf;
    BIO* outbuf;
    PKCS7* enc;
    int flags = 0;
    int err;
    BUF_MEM* bufmem;
    SV* result;

    inbuf = BIO_new_mem_buf(raw, -1);
    if (inbuf == NULL) {
	return NULL;
    }

    enc = PKCS7_encrypt(this->pubkeys_stack, inbuf, this->cipher, flags);
    BIO_free(inbuf);
    
    if (enc == NULL) {
	return NULL;
    }

    outbuf = BIO_new(BIO_s_mem());
    if (outbuf == NULL) {
	PKCS7_free(enc);
	return NULL;
    }

    err = SMIME_write_PKCS7(outbuf, enc, NULL, flags);
    PKCS7_free(enc);

    if (err != 1) {
	BIO_free(outbuf);
	return NULL;
    }

    BIO_get_mem_ptr(outbuf, &bufmem);
    result = newSVpv(bufmem->data, bufmem->length);
    BIO_free(outbuf);

    return result;
}

static SV* _decrypt(Crypt_SMIME this, char* encrypted_mime) {
    BIO* inbuf;
    BIO* outbuf;
    PKCS7* enc;
    int flags = 0;
    int err;
    BUF_MEM* bufmem;
    SV* result;

    inbuf = BIO_new_mem_buf(encrypted_mime, -1);
    if (inbuf == NULL) {
	return NULL;
    }

    enc = SMIME_read_PKCS7(inbuf, NULL);
    BIO_free(inbuf);

    if (enc == NULL) {
	return NULL;
    }

    outbuf = BIO_new(BIO_s_mem());
    if (outbuf == NULL) {
	PKCS7_free(enc);
	return NULL;
    }

    err = PKCS7_decrypt(enc, this->priv_key, this->priv_cert, outbuf, flags);
    PKCS7_free(enc);

    if (err != 1) {
	BIO_free(outbuf);
	return NULL;
    }

    BIO_get_mem_ptr(outbuf, &bufmem);
    result = newSVpv(bufmem->data, bufmem->length);
    BIO_free(outbuf);

    return result;
}

MODULE = Crypt::SMIME  PACKAGE = Crypt::SMIME

void
_init(char* /*CLASS*/)
    CODE:
        /* libcryptoの初期化 */
        ERR_load_crypto_strings();
        SSLeay_add_all_algorithms();

Crypt_SMIME
new(char* /*CLASS*/)
    CODE:
        RETVAL = safemalloc(sizeof(struct crypt_smime));
	if (RETVAL == NULL) {
	    croak("Crypt::SMIME#new: unable to allocate Crypt_SMIME");
	}

        memset(RETVAL, '\0', sizeof(struct crypt_smime));

    OUTPUT:
        RETVAL

void
DESTROY(Crypt_SMIME this)
    CODE:
        if (this->priv_cert) {
            X509_free(this->priv_cert);
        }
	if (this->priv_key) {
            EVP_PKEY_free(this->priv_key);
        }
	if (this->pubkeys_stack) {
	    sk_X509_free(this->pubkeys_stack);
	}
        if (this->pubkeys_store) {
            X509_STORE_free(this->pubkeys_store);
        }
        safefree(this);

SV*
setPrivateKey(Crypt_SMIME this, char* pem, char* crt, ...)
    PROTOTYPE: $$$;$
    PREINIT:
        char* password = "";
        STRLEN n_a;

    CODE:
        if (items > 3) {
            password = (char*)SvPV(ST(3), n_a);
        }

        /* 古い鍵があったら消す */
        if (this->priv_cert) {
            X509_free(this->priv_cert);
	    this->priv_cert = NULL;
        }
	if (this->priv_key) {
            EVP_PKEY_free(this->priv_key);
	    this->priv_key = NULL;
        }

	this->priv_key = load_privkey(this, pem, password);
 	if (this->priv_key == NULL) {
	    OPENSSL_CROAK("Crypt::SMIME#setPrivateKey: failed to load the private key");
        }

	this->priv_cert = load_cert(crt);
	if (this->priv_cert == NULL) {
	    OPENSSL_CROAK("Crypt::SMIME#setPrivateKey: failed to load the private cert");
	}

	SvREFCNT_inc(ST(0));
	RETVAL = ST(0);

    OUTPUT:
        RETVAL

SV*
setPublicKey(Crypt_SMIME this, SV* crt)
    CODE:
        /*
	    crt: ARRAY Refなら、その各要素が公開鍵
                 SCALARなら、それが公開鍵
        */

        /* 古い鍵があったら消す */
	if (this->pubkeys_stack) {
	    sk_X509_free(this->pubkeys_stack);
	    this->pubkeys_stack = NULL;
	}
	if (this->pubkeys_store) {
	    X509_STORE_free(this->pubkeys_store);
	    this->pubkeys_store = NULL;
	}

        this->pubkeys_store = X509_STORE_new();
	if (this->pubkeys_store == NULL) {
	    croak("Crypt::SMIME#new: failed to allocate X509_STORE");
	}

	/* 何故STACK_OF(X509)とX509_STOREの二つを使う必要があるのか。 */
	this->pubkeys_stack = sk_X509_new_null();
	if (this->pubkeys_stack == NULL) {
	    croak("Crypt::SMIME#setPublicKey: failed to allocate STACK_OF(X509)");
	}

	if (SvROK(crt) && SvTYPE(SvRV(crt)) == SVt_PVAV) {
	    AV* array = (AV*)SvRV(crt);
	    I32 i, len = av_len(array);

	    for (i = 0; i <= len; i++) {
	        SV** val = av_fetch(array, i, 1);
		if (val == NULL) {
		    continue; /* 多分起こらないが… */
                }

		if (SvPOK(*val)) {
		    SV* this_sv = ST(0);

		    dSP;
		    ENTER;
		    
		    PUSHMARK(SP);
		    XPUSHs(this_sv);
		    XPUSHs(*val);
		    PUTBACK;

		    call_method("_addPublicKey", G_DISCARD);

		    LEAVE;
		}
		else {
		    croak("Crypt::SMIME#setPublicKey: ARG[1] is an array but it contains some non-string values");
		}
	    }
	}
	else if (SvPOK(crt)) {
	    SV* this_sv = ST(0);

	    dSP;
	    ENTER;

	    PUSHMARK(SP);
	    XPUSHs(this_sv);
	    XPUSHs(crt);
	    PUTBACK;

	    call_method("_addPublicKey", G_DISCARD);

	    LEAVE;
	}
	else {
	    croak("Crypt::SMIME#setPublicKey: ARG[1] is not a string nor an ARRAY Ref");
	}

	SvREFCNT_inc(ST(0));
	RETVAL = ST(0);

    OUTPUT:
        RETVAL

void
_addPublicKey(Crypt_SMIME this, char* crt)
    PREINIT:
        BIO* buf;

    CODE:
        /* Be aware; 'crt' may contain two or more certificates.
        */
        buf = BIO_new_mem_buf(crt, -1);
        if (buf == NULL) {
            OPENSSL_CROAK("Crypt::SMIME#setPublicKey: failed to allocate a buffer");
        }

        ERR_clear_error();
        while (1) {
            X509* pub_cert;

            pub_cert = PEM_read_bio_X509_AUX(buf, NULL, NULL, NULL);
            if (pub_cert == NULL) {
                if (ERR_GET_REASON(ERR_peek_error()) == PEM_R_NO_START_LINE) {
                    ERR_clear_error();
                    break;
                }
                else {
                    BIO_free(buf);
                    OPENSSL_CROAK("Crypt::SMIME#setPublicKey: failed to load the public cert");
                }
            }

            if (X509_STORE_add_cert(this->pubkeys_store, pub_cert) == 0) {
                X509_free(pub_cert);
                BIO_free(buf);
                OPENSSL_CROAK("Crypt::SMIME#setPublicKey: failed to store the public cert");
            }

            pub_cert = X509_dup(pub_cert);
            if (pub_cert == NULL) {
                BIO_free(buf);
                OPENSSL_CROAK("Crypt::SMIME#setPublicKey: failed to duplicate the X509 structure");
            }

            if (sk_X509_push(this->pubkeys_stack, pub_cert) == 0) {
                X509_free(pub_cert);
                BIO_free(buf);
                OPENSSL_CROAK("Crypt::SMIME#setPublicKey: failed to push the public cert onto the stack");
            }
        }
        BIO_free(buf);

SV*
_sign(Crypt_SMIME this, char* raw)
    CODE:
        /* 秘密鍵がまだセットされていなければエラー */
        if (this->priv_key == NULL) {
	    croak("Crypt::SMIME#sign: private key has not yet been set. Set one before signing");
        }
        if (this->priv_cert == NULL) {
	    croak("Crypt::SMIME#sign: private cert has not yet been set. Set one before signing");
        }

        RETVAL = sign(this, raw);
        if (RETVAL == NULL) {
	    OPENSSL_CROAK("Crypt::SMIME#sign: failed to sign the message");
        }
	
    OUTPUT:
        RETVAL

SV*
_signonly(Crypt_SMIME this, char* raw)
    CODE:
        /* 秘密鍵がまだセットされていなければエラー */
        if (this->priv_key == NULL) {
	    croak("Crypt::SMIME#signonly: private key has not yet been set. Set one before signing");
        }
        if (this->priv_cert == NULL) {
	    croak("Crypt::SMIME#signonly: private cert has not yet been set. Set one before signing");
        }

        RETVAL = signonly(this, raw);
        if (RETVAL == NULL) {
	    OPENSSL_CROAK("Crypt::SMIME#signonly: failed to sign the message");
        }
	
    OUTPUT:
        RETVAL

SV*
_encrypt(Crypt_SMIME this, char* raw)
    CODE:
        /* 公開鍵がまだセットされていなければエラー */
	if (this->pubkeys_stack == NULL) {
	    croak("Crypt::SMIME#encrypt: public cert has not yet been set. Set one before encrypting");
	}

	/* cipherがまだ無ければ設定 */
	if (this->cipher == NULL) {
	    this->cipher = EVP_des_ede3_cbc();
	}

	RETVAL = _encrypt(this, raw);
	if (RETVAL == NULL) {
	    OPENSSL_CROAK("Crypt::SMIME#encrypt: failed to encrypt the message");
	}

    OUTPUT:
        RETVAL

SV*
check(Crypt_SMIME this, char* signed_mime)
    CODE:
        /* 公開鍵がまだセットされていなければエラー */
	if (this->pubkeys_store == NULL) {
	    croak("Crypt::SMIME#check: public cert has not yet been set. Set one before checking");
	}

	RETVAL = check(this, signed_mime);
	if (RETVAL == NULL) {
	    OPENSSL_CROAK("Crypt::SMIME#check: failed to check the signature");
	}

    OUTPUT:
        RETVAL

SV*
decrypt(Crypt_SMIME this, char* encrypted_mime)
    CODE:
        /* 秘密鍵がまだセットされていなければエラー */
        if (this->priv_key == NULL) {
	    croak("Crypt::SMIME#decrypt: private key has not yet been set. Set one before decrypting");
        }
        if (this->priv_cert == NULL) {
	    croak("Crypt::SMIME#decrypt: private cert has not yet been set. Set one before decrypting");
        }

	RETVAL = _decrypt(this, encrypted_mime);
        if (RETVAL == NULL) {
	    OPENSSL_CROAK("Crypt::SMIME#decrypt: failed to decrypt the message");
        }
	
    OUTPUT:
        RETVAL

SV*
x509_subject_hash(char* cert)
  CODE:
    {
      X509* x509 = load_cert(cert);
      if( x509!=NULL )
      {
        RETVAL = newSVuv(X509_subject_name_hash(x509));
        X509_free(x509);
      }else
      {
        RETVAL = &PL_sv_undef;
      }
    }
  OUTPUT:
    RETVAL

SV*
x509_issuer_hash(char* cert)
  CODE:
    {
      X509* x509 = load_cert(cert);
      if( x509!=NULL )
      {
        RETVAL = newSVuv(X509_issuer_name_hash(x509));
        X509_free(x509);
      }else
      {
        RETVAL = &PL_sv_undef;
      }
    }
  OUTPUT:
    RETVAL

# -----------------------------------------------------------------------------
# End of File.
# -----------------------------------------------------------------------------
