#import "GBearStreamSettings.h"

NS_ASSUME_NONNULL_BEGIN

@interface GBearStreamContext : NSObject

+ (instancetype)shared;

@property (nonatomic, strong, nullable) GBearStreamSettings *streamSettings;

@end

NS_ASSUME_NONNULL_END
