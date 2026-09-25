#import "GBearIdentity.h"

#import "CryptoManager.h"

#include <openssl/pem.h>
#include <openssl/pkcs12.h>
#include <openssl/x509.h>

@implementation GBearIdentity

+ (BOOL)syncMoonlightIdentityWithClientCertPem:(NSString *)certPem
                                 clientKeyPem:(NSString *)keyPem
                                     uniqueId:(NSString *)uniqueId
                                        error:(NSError **)error {
    if (certPem.length == 0 || keyPem.length == 0 || uniqueId.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"GBearMoonlight"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Missing client certificate material"}];
        }
        return NO;
    }

    [self resetCryptoManagerCaches];

    NSData *certData = [certPem dataUsingEncoding:NSUTF8StringEncoding];
    NSData *keyData = [keyPem dataUsingEncoding:NSUTF8StringEncoding];
    NSData *p12Data = [self exportP12FromCertData:certData keyData:keyData error:error];
    if (!p12Data) {
        return NO;
    }

    [CryptoManager writeCryptoObject:@"client.crt" data:certData];
    [CryptoManager writeCryptoObject:@"client.key" data:keyData];
    [CryptoManager writeCryptoObject:@"client.p12" data:p12Data];

    NSData *uniqueData = [uniqueId dataUsingEncoding:NSASCIIStringEncoding];
    [CryptoManager writeCryptoObject:@"uniqueid" data:uniqueData];

    [self resetCryptoManagerCaches];
    return YES;
}

+ (void)resetCryptoManagerCaches {
    [CryptoManager gbearResetCachedCredentials];
}

+ (NSData *)exportP12FromCertData:(NSData *)certData
                          keyData:(NSData *)keyData
                            error:(NSError **)error {
    BIO *certBio = BIO_new_mem_buf(certData.bytes, (int)certData.length);
    X509 *cert = PEM_read_bio_X509(certBio, NULL, NULL, NULL);
    BIO_free(certBio);
    if (!cert) {
        if (error) {
            *error = [NSError errorWithDomain:@"GBearMoonlight"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid client certificate PEM"}];
        }
        return nil;
    }

    BIO *keyBio = BIO_new_mem_buf(keyData.bytes, (int)keyData.length);
    EVP_PKEY *pkey = PEM_read_bio_PrivateKey(keyBio, NULL, NULL, NULL);
    BIO_free(keyBio);
    if (!pkey) {
        X509_free(cert);
        if (error) {
            *error = [NSError errorWithDomain:@"GBearMoonlight"
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid client private key PEM"}];
        }
        return nil;
    }

    PKCS12 *p12 = PKCS12_create("", NULL, pkey, cert, NULL, 0, 0, 0, 0, 0);
    EVP_PKEY_free(pkey);
    X509_free(cert);
    if (!p12) {
        if (error) {
            *error = [NSError errorWithDomain:@"GBearMoonlight"
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to create PKCS#12 identity"}];
        }
        return nil;
    }

    BIO *outBio = BIO_new(BIO_s_mem());
    i2d_PKCS12_bio(outBio, p12);
    PKCS12_free(p12);

    BUF_MEM *mem = NULL;
    BIO_get_mem_ptr(outBio, &mem);
    NSData *result = [NSData dataWithBytes:mem->data length:mem->length];
    BIO_free(outBio);
    return result;
}

@end
