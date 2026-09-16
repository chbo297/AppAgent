//
//  AppAgentDemo-Bridging-Header.h
//  AppAgentDemo
//
//  Exposes AppAgent's ObjC support (NSException catcher) to the demo app's
//  Swift sources. The demo compiles the AppAgent Swift sources directly (via a
//  filesystem-synchronized group) rather than through SwiftPM, so the ObjC
//  catcher is bridged in here instead of imported as a module.
//

#import "AppAgentObjCExceptionCatcher.h"
