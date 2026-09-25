#!/usr/bin/env python3
"""Apply GBear companion patches to synced moonlight-ios Limelight sources."""

from __future__ import annotations

import sys
from pathlib import Path


def patch_file(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text()
    if old not in text:
        raise SystemExit(f"{label}: expected snippet missing in {path}")
    path.write_text(text.replace(old, new, 1))


def patch_crypto_manager_h(limelight: Path) -> None:
    path = limelight / "Crypto/CryptoManager.h"
    patch_file(
        path,
        "@interface CryptoManager : NSObject\n",
        "@interface CryptoManager : NSObject\n\n"
        "+ (void)writeCryptoObject:(NSString *)item data:(NSData *)data;\n"
        "+ (void)gbearResetCachedCredentials;\n",
        "CryptoManager.h",
    )


def patch_crypto_manager_m(limelight: Path) -> None:
    path = limelight / "Crypto/CryptoManager.m"
    patch_file(
        path,
        "@end\n",
        "+ (void)gbearResetCachedCredentials {\n"
        "    key = nil;\n"
        "    cert = nil;\n"
        "    p12 = nil;\n"
        "}\n\n"
        "@end\n",
        "CryptoManager.m",
    )


def patch_stream_frame(limelight: Path) -> None:
    path = limelight / "ViewControllers/StreamFrameViewController.m"
    text = path.read_text()
    replacements = [
        (
            '#import "MainFrameViewController.h"\n',
            "",
        ),
        (
            '#import "DataManager.h"\n',
            '#import "GBearStreamContext.h"\n#import "GBearStreamSettings.h"\n',
        ),
        (
            "    TemporarySettings *_settings;\n",
            "    GBearStreamSettings *_settings;\n",
        ),
        (
            "    _settings = [[[DataManager alloc] init] getSettings];\n",
            "    _settings = [GBearStreamContext shared].streamSettings;\n"
            "    NSAssert(_settings != nil, @\"GBear stream settings were not configured\");\n",
        ),
        (
            "#if !TARGET_OS_TV\n"
            "    [[self revealViewController] setPrimaryViewController:self];\n"
            "#endif\n",
            "#if !TARGET_OS_TV && !defined(GBEAR_COMPANION)\n"
            "    [[self revealViewController] setPrimaryViewController:self];\n"
            "#endif\n",
        ),
        (
            "- (void) returnToMainFrame {\n"
            "    // Reset display mode back to default\n"
            "    [self updatePreferredDisplayMode:NO];\n"
            "    \n"
            "    [_statsUpdateTimer invalidate];\n"
            "    _statsUpdateTimer = nil;\n"
            "    \n"
            "    [self.navigationController popToRootViewControllerAnimated:YES];\n"
            "}",
            "- (void) returnToMainFrame {\n"
            "    [self updatePreferredDisplayMode:NO];\n"
            "    \n"
            "    [_statsUpdateTimer invalidate];\n"
            "    _statsUpdateTimer = nil;\n"
            "    \n"
            "    [[NSNotificationCenter defaultCenter] postNotificationName:"
            "GBearMoonlightStreamDidEndNotification object:nil];\n"
            "    if (self.navigationController.presentingViewController) {\n"
            "        [self.navigationController.presentingViewController "
            "dismissViewControllerAnimated:YES completion:nil];\n"
            "    } else {\n"
            "        [self.navigationController popToRootViewControllerAnimated:YES];\n"
            "    }\n"
            "}",
        ),
    ]
    for old, new in replacements:
        if old not in text:
            raise SystemExit(f"StreamFrameViewController.m: missing snippet in {path}")
        text = text.replace(old, new, 1)
    path.write_text(text)
    patch_file(
        path,
        '#import "StreamFrameViewController.h"\n',
        '#import "StreamFrameViewController.h"\n'
        '#import "GBearStreamLaunchHelper.h"\n'
        '#import "Utils.h"\n',
        "StreamFrame import launch helper",
    )


def patch_controller_support(limelight: Path) -> None:
    path = limelight / "Input/ControllerSupport.m"
    patch_file(
        path,
        '#import "DataManager.h"\n',
            '#import "GBearStreamContext.h"\n#import "GBearStreamSettings.h"\n',
        "ControllerSupport import",
    )
    patch_file(
        path,
        "    DataManager* dataMan = [[DataManager alloc] init];\n"
        "    TemporarySettings* settings = [dataMan getSettings];\n",
        "    GBearStreamSettings* settings = [GBearStreamContext shared].streamSettings;\n",
        "ControllerSupport mask settings",
    )
    patch_file(
        path,
        "    DataManager* dataMan = [[DataManager alloc] init];\n"
        "    _oscEnabled = (OnScreenControlsLevel)[[dataMan getSettings].onscreenControls integerValue] != OnScreenControlsLevelOff;\n",
        "    GBearStreamSettings* settings = [GBearStreamContext shared].streamSettings;\n"
        "    _oscEnabled = (OnScreenControlsLevel)[settings.onscreenControls integerValue] != OnScreenControlsLevelOff;\n",
        "ControllerSupport osc",
    )


def patch_stream_view_header(limelight: Path) -> None:
    path = limelight / "Input/StreamView.h"
    patch_file(
        path,
        '#import "Moonlight-Swift.h"\n',
        "@protocol X1KitMouseDelegate;\n",
        "StreamView swift header",
    )
    patch_file(
        path,
        "#if TARGET_OS_TV\n"
        "@interface StreamView : UIView <X1KitMouseDelegate, UITextFieldDelegate>\n"
        "#else\n"
        "@interface StreamView : UIView <X1KitMouseDelegate, UITextFieldDelegate, UIPointerInteractionDelegate>\n"
        "#endif\n",
        "#if !defined(GBEAR_COMPANION)\n"
        "#if TARGET_OS_TV\n"
        "@interface StreamView : UIView <X1KitMouseDelegate, UITextFieldDelegate>\n"
        "#else\n"
        "@interface StreamView : UIView <X1KitMouseDelegate, UITextFieldDelegate, UIPointerInteractionDelegate>\n"
        "#endif\n"
        "#else\n"
        "#if TARGET_OS_TV\n"
        "@interface StreamView : UIView <UITextFieldDelegate>\n"
        "#else\n"
        "@interface StreamView : UIView <UITextFieldDelegate, UIPointerInteractionDelegate>\n"
        "#endif\n"
        "#endif\n",
        "StreamView interface",
    )


def patch_stream_view(limelight: Path) -> None:
    path = limelight / "Input/StreamView.m"
    patch_file(
        path,
        '#import "StreamView.h"\n',
        '#import "StreamView.h"\n#import <objc/runtime.h>\n',
        "StreamView objc runtime",
    )
    patch_file(
        path,
        '#import "DataManager.h"\n',
        '#import "GBearStreamContext.h"\n#import "GBearStreamSettings.h"\n',
        "StreamView import",
    )
    patch_file(
        path,
        "    TemporarySettings* settings = [[[DataManager alloc] init] getSettings];\n",
        "    GBearStreamSettings* settings = [GBearStreamContext shared].streamSettings;\n",
        "StreamView settings",
    )
    patch_file(
        path,
        "    // Citrix X1 mouse support\n"
        "    X1Mouse* x1mouse;\n",
        "#if !defined(GBEAR_COMPANION)\n"
        "    // Citrix X1 mouse support\n"
        "    X1Mouse* x1mouse;\n"
        "#endif\n",
        "StreamView x1 ivar",
    )
    patch_file(
        path,
        "    x1mouse = [[X1Mouse alloc] init];\n"
        "    x1mouse.delegate = self;\n"
        "    \n"
        "    if (settings.btMouseSupport) {\n"
        "        [x1mouse start];\n"
        "    }\n"
        "    \n",
        "#if !defined(GBEAR_COMPANION)\n"
        "    x1mouse = [[X1Mouse alloc] init];\n"
        "    x1mouse.delegate = self;\n"
        "    \n"
        "    if (settings.btMouseSupport) {\n"
        "        [x1mouse start];\n"
        "    }\n"
        "    \n"
        "#endif\n"
        "    \n",
        "StreamView x1 init",
    )
    patch_file(
        path,
        "- (void)connectedStateDidChangeWithIdentifier:(NSUUID * _Nonnull)identifier isConnected:(BOOL)isConnected {\n"
        "    NSLog(@\"Citrix X1 mouse state change: %@ -> %s\",\n"
        "          identifier, isConnected ? \"connected\" : \"disconnected\");\n"
        "}\n\n"
        "- (void)mouseDidMoveWithIdentifier:(NSUUID * _Nonnull)identifier deltaX:(int16_t)deltaX deltaY:(int16_t)deltaY {\n"
        "    accumulatedMouseDeltaX += deltaX / X1_MOUSE_SPEED_DIVISOR;\n"
        "    accumulatedMouseDeltaY += deltaY / X1_MOUSE_SPEED_DIVISOR;\n"
        "    \n"
        "    short shortX = (short)accumulatedMouseDeltaX;\n"
        "    short shortY = (short)accumulatedMouseDeltaY;\n"
        "    \n"
        "    if (shortX == 0 && shortY == 0) {\n"
        "        return;\n"
        "    }\n"
        "    \n"
        "    LiSendMouseMoveEvent(shortX, shortY);\n"
        "    \n"
        "    accumulatedMouseDeltaX -= shortX;\n"
        "    accumulatedMouseDeltaY -= shortY;\n"
        "}\n\n"
        "- (int) buttonFromX1ButtonCode:(enum X1MouseButton)button {\n"
        "    switch (button) {\n"
        "        case X1MouseButtonLeft:\n"
        "            return BUTTON_LEFT;\n"
        "        case X1MouseButtonRight:\n"
        "            return BUTTON_RIGHT;\n"
        "        case X1MouseButtonMiddle:\n"
        "            return BUTTON_MIDDLE;\n"
        "        default:\n"
        "            return -1;\n"
        "    }\n"
        "}\n\n"
        "- (void)mouseDownWithIdentifier:(NSUUID * _Nonnull)identifier button:(enum X1MouseButton)button {\n"
        "    LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, [self buttonFromX1ButtonCode:button]);\n"
        "}\n\n"
        "- (void)mouseUpWithIdentifier:(NSUUID * _Nonnull)identifier button:(enum X1MouseButton)button {\n"
        "    LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, [self buttonFromX1ButtonCode:button]);\n"
        "}\n\n"
        "- (void)wheelDidScrollWithIdentifier:(NSUUID * _Nonnull)identifier deltaZ:(int8_t)deltaZ {\n"
        "    LiSendScrollEvent(deltaZ);\n"
        "}\n\n",
        "#if !defined(GBEAR_COMPANION)\n"
        "- (void)connectedStateDidChangeWithIdentifier:(NSUUID * _Nonnull)identifier isConnected:(BOOL)isConnected {\n"
        "    NSLog(@\"Citrix X1 mouse state change: %@ -> %s\",\n"
        "          identifier, isConnected ? \"connected\" : \"disconnected\");\n"
        "}\n\n"
        "- (void)mouseDidMoveWithIdentifier:(NSUUID * _Nonnull)identifier deltaX:(int16_t)deltaX deltaY:(int16_t)deltaY {\n"
        "    accumulatedMouseDeltaX += deltaX / X1_MOUSE_SPEED_DIVISOR;\n"
        "    accumulatedMouseDeltaY += deltaY / X1_MOUSE_SPEED_DIVISOR;\n"
        "    \n"
        "    short shortX = (short)accumulatedMouseDeltaX;\n"
        "    short shortY = (short)accumulatedMouseDeltaY;\n"
        "    \n"
        "    if (shortX == 0 && shortY == 0) {\n"
        "        return;\n"
        "    }\n"
        "    \n"
        "    LiSendMouseMoveEvent(shortX, shortY);\n"
        "    \n"
        "    accumulatedMouseDeltaX -= shortX;\n"
        "    accumulatedMouseDeltaY -= shortY;\n"
        "}\n\n"
        "- (int) buttonFromX1ButtonCode:(enum X1MouseButton)button {\n"
        "    switch (button) {\n"
        "        case X1MouseButtonLeft:\n"
        "            return BUTTON_LEFT;\n"
        "        case X1MouseButtonRight:\n"
        "            return BUTTON_RIGHT;\n"
        "        case X1MouseButtonMiddle:\n"
        "            return BUTTON_MIDDLE;\n"
        "        default:\n"
        "            return -1;\n"
        "    }\n"
        "}\n\n"
        "- (void)mouseDownWithIdentifier:(NSUUID * _Nonnull)identifier button:(enum X1MouseButton)button {\n"
        "    LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, [self buttonFromX1ButtonCode:button]);\n"
        "}\n\n"
        "- (void)mouseUpWithIdentifier:(NSUUID * _Nonnull)identifier button:(enum X1MouseButton)button {\n"
        "    LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, [self buttonFromX1ButtonCode:button]);\n"
        "}\n\n"
        "- (void)wheelDidScrollWithIdentifier:(NSUUID * _Nonnull)identifier deltaZ:(int8_t)deltaZ {\n"
        "    LiSendScrollEvent(deltaZ);\n"
        "}\n\n"
        "#endif\n\n",
        "StreamView x1 delegate methods",
    )


def patch_http_manager_imports(limelight: Path) -> None:
    path = limelight / "Network/HttpManager.m"
    patch_file(
        path,
        '#import "TemporaryApp.h"\n',
        "",
        "HttpManager TemporaryApp import",
    )


def patch_connection_opus(limelight: Path) -> None:
    path = limelight / "Stream/Connection.m"
    patch_file(
        path,
        '#include "opus_multistream.h"\n',
        '#include <opus/opus_multistream.h>\n',
        "Connection opus include",
    )


def patch_http_response(limelight: Path) -> None:
    path = limelight / "Network/HttpResponse.m"
    patch_file(
        path,
        '#import "TemporaryApp.h"\n',
        "",
        "HttpResponse import",
    )


def patch_http_manager(limelight: Path) -> None:
    path = limelight / "Network/HttpManager.m"
    patch_file(
        path,
        "            TemporaryHost* dummyHost = [[TemporaryHost alloc] init];\n"
        "            if (![serverInfoResponse isStatusOk]) {\n"
        "                return NO;\n"
        "            }\n"
        "            [serverInfoResponse populateHost:dummyHost];\n"
        "            \n"
        "            // Pass the port back if the caller provided storage for it\n"
        "            if (_host) {\n"
        "                _host.httpsPort = dummyHost.httpsPort;\n"
        "            }\n"
        "            \n"
        "            _baseHTTPSURL = [NSString stringWithFormat:@\"https://%@:%u\", _urlSafeHostName, dummyHost.httpsPort];\n",
        "            if (![serverInfoResponse isStatusOk]) {\n"
        "                return NO;\n"
        "            }\n"
        "            NSString* httpsPortTag = [serverInfoResponse getStringTag:@\"HttpsPort\"];\n"
        "            unsigned short resolvedPort = httpsPortTag ? (unsigned short)[httpsPortTag intValue] : 47984;\n"
        "            if (_host) {\n"
        "                _host.httpsPort = resolvedPort;\n"
        "            }\n"
        "            _baseHTTPSURL = [NSString stringWithFormat:@\"https://%@:%u\", _urlSafeHostName, resolvedPort];\n",
        "HttpManager https port",
    )


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} <limelight-sources-dir>")
    limelight = Path(sys.argv[1])
    patch_crypto_manager_h(limelight)
    patch_crypto_manager_m(limelight)
    patch_stream_frame(limelight)
    patch_controller_support(limelight)
    patch_stream_view_header(limelight)
    patch_stream_view(limelight)
    patch_http_response(limelight)
    patch_http_manager_imports(limelight)
    patch_http_manager(limelight)
    patch_connection_opus(limelight)


if __name__ == "__main__":
    main()
