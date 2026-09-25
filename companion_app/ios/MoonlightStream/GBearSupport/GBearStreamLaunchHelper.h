#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const GBearMoonlightStreamDidEndNotification;

@interface GBearStreamLaunchHelper : NSObject

+ (BOOL)startStreamFromViewController:(UIViewController *)viewController
                            arguments:(NSDictionary *)arguments;

+ (NSString * _Nullable)lastStreamStartErrorMessage;

+ (void)stopStream;

@end

NS_ASSUME_NONNULL_END
