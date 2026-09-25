#import "GBearStreamLaunchHelper.h"

#import "GBearIdentity.h"
#import "GBearStreamContext.h"
#import "GBearStreamSettings.h"
#import "StreamConfiguration.h"
#import "StreamFrameViewController.h"
#import "ControllerSupport.h"

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include <Limelight.h>

NSNotificationName const GBearMoonlightStreamDidEndNotification =
    @"GBearMoonlightStreamDidEndNotification";

static UINavigationController *gbearActiveStreamNavigationController;
static NSString *gbearLastStreamStartErrorMessage;

@implementation GBearStreamLaunchHelper

+ (NSString *)lastStreamStartErrorMessage {
    return gbearLastStreamStartErrorMessage;
}

+ (BOOL)startStreamFromViewController:(UIViewController *)viewController
                            arguments:(NSDictionary *)arguments {
    gbearLastStreamStartErrorMessage = nil;
    NSString *host = arguments[@"hostAddress"];
    NSNumber *httpPort = arguments[@"httpPort"];
    NSNumber *httpsPort = arguments[@"httpsPort"];
    NSNumber *appId = arguments[@"appId"];
    NSString *appName = arguments[@"appName"];
    NSString *clientCertPem = arguments[@"clientCertPem"];
    NSString *clientKeyPem = arguments[@"clientKeyPem"];
    NSString *serverCertB64 = arguments[@"serverCertDerBase64"];
    NSNumber *width = arguments[@"width"];
    NSNumber *height = arguments[@"height"];
    NSNumber *fps = arguments[@"fps"];
    NSString *uniqueId = arguments[@"uniqueId"] ?: @"0123456789ABCDEF";

    if (host.length == 0 || httpPort == nil || httpsPort == nil || appId == nil ||
        clientCertPem.length == 0 || clientKeyPem.length == 0 || serverCertB64.length == 0 ||
        width == nil || height == nil || fps == nil) {
        gbearLastStreamStartErrorMessage = @"Missing stream launch arguments";
        return NO;
    }

    NSError *identityError = nil;
    if (![GBearIdentity syncMoonlightIdentityWithClientCertPem:clientCertPem
                                                    clientKeyPem:clientKeyPem
                                                        uniqueId:uniqueId
                                                           error:&identityError]) {
        gbearLastStreamStartErrorMessage =
            identityError.localizedDescription ?: @"Could not sync Moonlight client certificate";
        return NO;
    }

    NSData *serverCert = [[NSData alloc] initWithBase64EncodedString:serverCertB64 options:0];
    if (serverCert.length == 0) {
        gbearLastStreamStartErrorMessage = @"Invalid pinned server certificate";
        return NO;
    }

    int streamWidth = width.intValue;
    int streamHeight = height.intValue;
    int streamFps = fps.intValue;

    GBearStreamSettings *settings =
        [GBearStreamSettings settingsWithWidth:streamWidth height:streamHeight frameRate:streamFps];

    NSNumber *multiController = arguments[@"multiController"];
    if (multiController != nil) {
        settings.multiController = multiController.boolValue;
    }
    NSNumber *swapFaceButtons = arguments[@"swapFaceButtons"];
    if (swapFaceButtons != nil) {
        settings.swapABXYButtons = swapFaceButtons.boolValue;
    }
    NSNumber *onScreenControls = arguments[@"onScreenControls"];
    if (onScreenControls != nil) {
        settings.onscreenControls = onScreenControls.boolValue ? @(1) : @(0);
    }

    [GBearStreamContext shared].streamSettings = settings;

    StreamConfiguration *config = [[StreamConfiguration alloc] init];
    config.host = [NSString stringWithFormat:@"%@:%d", host, httpPort.intValue];
    config.httpsPort = (unsigned short)httpsPort.intValue;
    config.appID = [NSString stringWithFormat:@"%d", appId.intValue];
    config.appName = appName.length > 0 ? appName : @"Desktop";
    config.serverCert = serverCert;
    config.frameRate = streamFps;
    if (@available(iOS 10.3, *)) {
        if (config.frameRate > (int)UIScreen.mainScreen.maximumFramesPerSecond) {
            config.frameRate = (int)UIScreen.mainScreen.maximumFramesPerSecond;
        }
    }
    config.width = streamWidth;
    config.height = streamHeight;
    config.bitRate = settings.bitrate.intValue;
    config.optimizeGameSettings = settings.optimizeGames;
    config.playAudioOnPC = settings.playAudioOnPC;
    config.useFramePacing = settings.useFramePacing;
    config.swapABXYButtons = settings.swapABXYButtons;
    config.multiController = settings.multiController;
    config.gamepadMask = [ControllerSupport getConnectedGamepadMask:config];

    int physicalOutputChannels = (int)AVAudioSession.sharedInstance.maximumOutputNumberOfChannels;
    int numberOfChannels = MIN(settings.audioConfig.intValue, physicalOutputChannels);
    if (numberOfChannels >= 8) {
        config.audioConfiguration = AUDIO_CONFIGURATION_71_SURROUND;
    } else if (numberOfChannels >= 6) {
        config.audioConfiguration = AUDIO_CONFIGURATION_51_SURROUND;
    } else {
        config.audioConfiguration = AUDIO_CONFIGURATION_STEREO;
    }

    config.serverCodecModeSupport = 0;
    config.supportedVideoFormats = 0;
    if (VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
        config.supportedVideoFormats |= VIDEO_FORMAT_H265;
    }
    config.supportedVideoFormats |= VIDEO_FORMAT_H264;

    StreamFrameViewController *streamController = [[StreamFrameViewController alloc] init];
    streamController.streamConfig = config;

    UINavigationController *navigationController =
        [[UINavigationController alloc] initWithRootViewController:streamController];
    navigationController.modalPresentationStyle = UIModalPresentationFullScreen;
    navigationController.navigationBarHidden = YES;
    gbearActiveStreamNavigationController = navigationController;

    [viewController presentViewController:navigationController animated:YES completion:nil];
    return YES;
}

+ (void)stopStream {
    UINavigationController *navigationController = gbearActiveStreamNavigationController;
    gbearActiveStreamNavigationController = nil;
    [navigationController.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

@end
