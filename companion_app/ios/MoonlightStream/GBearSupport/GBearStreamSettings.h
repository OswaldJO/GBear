#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// In-memory stream settings for the companion app (no Core Data).
@interface GBearStreamSettings : NSObject

@property (nonatomic, retain) NSNumber *bitrate;
@property (nonatomic, retain) NSNumber *framerate;
@property (nonatomic, retain) NSNumber *height;
@property (nonatomic, retain) NSNumber *width;
@property (nonatomic, retain) NSNumber *audioConfig;
@property (nonatomic, retain) NSNumber *onscreenControls;
@property (nonatomic) int preferredCodec;
@property (nonatomic) BOOL useFramePacing;
@property (nonatomic) BOOL multiController;
@property (nonatomic) BOOL swapABXYButtons;
@property (nonatomic) BOOL playAudioOnPC;
@property (nonatomic) BOOL optimizeGames;
@property (nonatomic) BOOL enableHdr;
@property (nonatomic) BOOL btMouseSupport;
@property (nonatomic) BOOL absoluteTouchMode;
@property (nonatomic) BOOL statsOverlay;

+ (instancetype)settingsWithWidth:(int)width height:(int)height frameRate:(int)frameRate;

@end

NS_ASSUME_NONNULL_END
