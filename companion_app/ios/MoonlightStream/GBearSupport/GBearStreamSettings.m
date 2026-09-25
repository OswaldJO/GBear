#import "GBearStreamSettings.h"

@implementation GBearStreamSettings

+ (instancetype)settingsWithWidth:(int)width height:(int)height frameRate:(int)frameRate {
    GBearStreamSettings *settings = [[GBearStreamSettings alloc] init];
    settings.width = @(width);
    settings.height = @(height);
    settings.framerate = @(frameRate);
    settings.bitrate = @(20000);
    settings.audioConfig = @(2);
    settings.onscreenControls = @(0);
    settings.preferredCodec = 1; // CODEC_PREF_AUTO
    settings.useFramePacing = YES;
    settings.multiController = YES;
    settings.swapABXYButtons = NO;
    settings.playAudioOnPC = NO;
    settings.optimizeGames = YES;
    settings.enableHdr = NO;
    settings.btMouseSupport = NO;
    settings.absoluteTouchMode = NO;
    settings.statsOverlay = NO;
    return settings;
}

@end
