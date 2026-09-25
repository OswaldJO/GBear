#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GBearIdentity : NSObject

+ (BOOL)syncMoonlightIdentityWithClientCertPem:(NSString *)certPem
                                 clientKeyPem:(NSString *)keyPem
                                     uniqueId:(NSString *)uniqueId
                                        error:(NSError * _Nullable * _Nullable)error;

+ (void)resetCryptoManagerCaches;

@end

NS_ASSUME_NONNULL_END
