//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

#import "PdAudioController.h"
#import "PdDispatcher.h"
#import "PdBase.h"
#import "PdBase_Extension.h"
#import "F53OSC.h"
#import "F53OSCProtocols.h"
#import "F53OSCParser.h"
#import "F53OSCSocket.h"
#import "F53OSCPacket.h"
#import "F53OSCMessage.h"
#import "F53OSCBundle.h"
#import "F53OSCClient.h"
#import "F53OSCServer.h"
#import "F53OSCTimeTag.h"
#import "vas_fir_binaural.h"
#import "rwa_binauralsimple~.h"
#import "vas_reverb~.h"
#include <ifaddrs.h>

extern void freeverb_tilde_setup(void);
extern void oggread_tilde_setup(void);


