//
//  GBAEmulatorBridge.m
//  GBADeltaCore
//
//  Created by Riley Testut on 6/3/16.
//  Copyright © 2016 Riley Testut. All rights reserved.
//

#import "GBAEmulatorBridge.h"
#import "GBASoundDriver.h"

#import <CoreMotion/CoreMotion.h>

// VBA-M
#include "core/base/system.h"
#include "core/base/message.h"
#include "core/base/file_util.h"
#include "core/gba/gba.h"
#include "core/gba/gbaGlobals.h"
#include "core/gba/gbaSound.h"
#include "core/gba/gbaCheats.h"
#include "core/gba/gbaRtc.h"
#include "core/gba/gbaFlash.h"
#include "core/gba/gbaEeprom.h"

#include <sys/time.h>

// DeltaCore
#import <GBADeltaCore/GBADeltaCore.h>
#import <DeltaCore/DeltaCore.h>
#import <DeltaCore/DeltaCore-Swift.h>

#if STATIC_LIBRARY
#import "GBADeltaCore-Swift.h"
#import "GBATypes.h"
#else
#import <GBADeltaCore/GBADeltaCore-Swift.h>
#endif

// Required vars, used by the emulator core
//
int  systemRedShift = 19;
int  systemGreenShift = 11;
int  systemBlueShift = 3;
int  systemColorDepth = 32;
int  systemVerbose;
int  systemSaveUpdateCounter = 0;
int  systemFrameSkip;
int  systemSpeed = 0;
uint32_t  systemColorMap32[0x10000];
uint16_t  systemColorMap16[0x10000];
uint8_t   systemColorMap8[0x10000];
uint16_t  systemGbPalette[24];

int  emulating;
int  RGB_LOW_BITS_MASK;

// Core-wide option block (declared extern in core/base/system.h; the embedder owns the instance).
struct CoreOptions coreOptions;

// Debugger hooks; unused in Delta.
void (*dbgOutput)(const char *s, uint32_t addr) = NULL;
void (*dbgSignal)(int sig, int number) = NULL;

// Equivalent of the old utilUpdateSystemColorMaps(false): expand RGB555 to the 32-bit layout
// described by systemRed/Green/BlueShift.
static void GBAUpdateSystemColorMap(void)
{
    for (int i = 0; i < 0x10000; i++)
    {
        systemColorMap32[i] = ((i & 0x1f) << systemRedShift) |
                              (((i & 0x3e0) >> 5) << systemGreenShift) |
                              (((i & 0x7c00) >> 10) << systemBlueShift);
    }
}

@interface GBAEmulatorBridge ()

@property (nonatomic, copy, nullable, readwrite) NSURL *gameURL;

@property (assign, nonatomic, getter=isFrameReady) BOOL frameReady;

// Whether CPUReset() has built the memory map for the current game. armExecute() dereferences that map
// unconditionally, so running a frame after a failed load crashes (Crashlytics 69434e0e).
@property (assign, nonatomic, getter=isGameLoaded) BOOL gameLoaded;

@property (nonatomic) uint32_t activatedInputs;

@property (strong, nonatomic, readonly) CMMotionManager *motionManager;

@end

@implementation GBAEmulatorBridge
@synthesize audioRenderer = _audioRenderer;
@synthesize videoRenderer = _videoRenderer;
@synthesize saveUpdateHandler = _saveUpdateHandler;

+ (instancetype)sharedBridge
{
    static GBAEmulatorBridge *_emulatorBridge = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _emulatorBridge = [[self alloc] init];
    });
    
    return _emulatorBridge;
}

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _motionManager = [[CMMotionManager alloc] init];
    }
    
    return self;
}

#pragma mark - Emulation -

- (void)startWithGameURL:(NSURL *)URL
{
    self.gameURL = URL;
    self.gameLoaded = NO;
    
    // Upstream defaults skipSaveGameBattery to 1, but the 2018 core (and every save state Delta has written so far)
    // embeds the battery save in the state. Keep that so existing states load with their saves intact.
    coreOptions.skipSaveGameBattery = 0;
    coreOptions.skipSaveGameCheats = 0;
    
    NSData *data = [NSData dataWithContentsOfURL:URL];
    
    if (data.length == 0 || data.length > SIZE_ROM * 4 || !CPULoadRomData((const char *)data.bytes, (int)data.length))
    {
        NSLog(@"[GBADeltaCore] Failed to load ROM (%lu bytes): %@", (unsigned long)data.length, URL.lastPathComponent);
        return;
    }
        
    GBAUpdateSystemColorMap();
    flashDetectSaveType((int)data.length);
    
    // Update per-game settings after flashDetectSaveType determines defaults.
    [self updateGameSettings];
    
    // Upstream (ec46bf83) answers every ROM read from the EEPROM state machine while eepromMask == 0,
    // and eepromSetSize() is the only thing that sets the mask. Without this, EEPROM/AUTO games read
    // zeros from ROM and never get past the first frame. Same workaround as the wx/sdl/libretro frontends.
    eepromSetSize(SIZE_EEPROM_512);
    
    soundInit();
    soundSetSampleRate(32768); // 44100 chirps
    
    soundReset();
    
    CPUInit(0, false);
    
    GBASystem.emuReset();
    
    self.gameLoaded = YES;
    emulating = 1;
}

- (void)stop
{
    self.gameLoaded = NO;
    
    GBASystem.emuCleanUp();
    soundShutdown();
    
    emulating = 0;
    
    [self deactivateGyroscope];
}

- (void)pause
{
    emulating = 0;
    
    [self deactivateGyroscope];
}

- (void)resume
{
    emulating = 1;
}

- (void)runFrameAndProcessVideo:(BOOL)processVideo
{
    if (![self isGameLoaded])
    {
        return;
    }
    
    self.frameReady = NO;
    
    while (![self isFrameReady])
    {
        GBASystem.emuMain(GBASystem.emuCount);
    }
}

- (nullable NSData *)readMemoryAtAddress:(NSInteger)address size:(NSInteger)size
{
    if (g_workRAM == NULL)
    {
        return nil;
    }
    
    void *bytes = NULL;
    if (address >= 0x8000)
    {
        bytes = (void *)(g_workRAM + address - 0x8000);
    }
    else
    {
        bytes = (void *)(g_internalRAM + address);
    }
    
    NSData *data = [NSData dataWithBytesNoCopy:bytes length:size freeWhenDone:NO];
    return data;
}

#pragma mark - Settings -

- (void)updateGameSettings
{
    NSString *gameID = [NSString stringWithFormat:@"%c%c%c%c", g_rom[0xac], g_rom[0xad], g_rom[0xae], g_rom[0xaf]];
    
    NSLog(@"VBA-M: GameID in ROM is: %@", gameID);
    
    // Set defaults
    // Use underscores to prevent shadowing of global variables
    BOOL _enableRTC       = NO;
    BOOL _enableMirroring = NO;
    BOOL _useBIOS         = NO;
    int  _cpuSaveType     = 0;
    int  _flashSize       = 0x10000;
    
    // Read in vba-over.ini and break it into an array of strings
    NSString *iniPath = [GBAEmulatorBridge.gbaResources pathForResource:@"vba-over" ofType:@"ini"];
    NSString *iniString = [NSString stringWithContentsOfFile:iniPath encoding:NSUTF8StringEncoding error:NULL];
    NSArray *settings = [iniString componentsSeparatedByString:@"\n"];
    
    BOOL matchFound = NO;
    NSMutableDictionary *overridesFound = [[NSMutableDictionary alloc] init];
    NSString *temp;
    
    // Check if vba-over.ini has per-game settings for our gameID
    for (NSString *s in settings)
    {
        temp = nil;
        
        if ([s hasPrefix:@"["])
        {
            NSScanner *scanner = [NSScanner scannerWithString:s];
            [scanner scanString:@"[" intoString:nil];
            [scanner scanUpToString:@"]" intoString:&temp];
            
            if ([temp caseInsensitiveCompare:gameID] == NSOrderedSame)
            {
                matchFound = YES;
            }
            
            continue;
        }
        
        else if (matchFound && [s hasPrefix:@"saveType="])
        {
            NSScanner *scanner = [NSScanner scannerWithString:s];
            [scanner scanString:@"saveType=" intoString:nil];
            [scanner scanUpToString:@"\n" intoString:&temp];
            _cpuSaveType = [temp intValue];
            [overridesFound setObject:temp forKey:@"CPU saveType"];
            
            continue;
        }
        
        else if (matchFound && [s hasPrefix:@"rtcEnabled="])
        {
            NSScanner *scanner = [NSScanner scannerWithString:s];
            [scanner scanString:@"rtcEnabled=" intoString:nil];
            [scanner scanUpToString:@"\n" intoString:&temp];
            _enableRTC = [temp boolValue];
            [overridesFound setObject:temp forKey:@"rtcEnabled"];
            
            continue;
        }
        
        else if (matchFound && [s hasPrefix:@"flashSize="])
        {
            NSScanner *scanner = [NSScanner scannerWithString:s];
            [scanner scanString:@"flashSize=" intoString:nil];
            [scanner scanUpToString:@"\n" intoString:&temp];
            _flashSize = [temp intValue];
            [overridesFound setObject:temp forKey:@"flashSize"];
            
            continue;
        }
        
        else if (matchFound && [s hasPrefix:@"mirroringEnabled="])
        {
            NSScanner *scanner = [NSScanner scannerWithString:s];
            [scanner scanString:@"mirroringEnabled=" intoString:nil];
            [scanner scanUpToString:@"\n" intoString:&temp];
            _enableMirroring = [temp boolValue];
            [overridesFound setObject:temp forKey:@"mirroringEnabled"];
            
            continue;
        }
        
        else if (matchFound && [s hasPrefix:@"useBios="])
        {
            NSScanner *scanner = [NSScanner scannerWithString:s];
            [scanner scanString:@"useBios=" intoString:nil];
            [scanner scanUpToString:@"\n" intoString:&temp];
            _useBIOS = [temp boolValue];
            [overridesFound setObject:temp forKey:@"useBios"];
            
            continue;
        }
        
        else if (matchFound)
            break;
    }
    
    // Some hacked games use the RealTimeClock even when the game they're based off of doesn't (ex: Pokemon Liquid Crystal), so we always have it enabled.
    coreOptions.rtcEnabled = 1;
    rtcEnable(true);
    
    if (!matchFound)
    {
        // Only update remaining settings if we found a match.
        return;
    }
    
    NSLog(@"VBA: overrides found: %@", overridesFound);
    
    // Apply settings
    coreOptions.mirroringEnable = _enableMirroring;
    doMirroring(coreOptions.mirroringEnable);
    
    // vba-over.ini saveType matches GBA_SAVE_* (0 auto, 1 EEPROM, 2 SRAM, 3 flash, 4 EEPROM+sensor, 5 none).
    // 0 keeps the type flashDetectSaveType() found (2018 core semantics; wx does the same).
    // CPUReset() applies coreOptions.saveType via SetSaveType().
    coreOptions.cpuSaveType = _cpuSaveType;
    if (_cpuSaveType > GBA_SAVE_AUTO && _cpuSaveType <= GBA_SAVE_NONE)
    {
        coreOptions.saveType = _cpuSaveType;
    }
    
    // Delta doesn't use BIOS files.
    // useBios = _useBIOS;
    
    if (_flashSize == 0x10000 || _flashSize == 0x20000)
    {
        flashSetSize(_flashSize);
    }
    
}

#pragma mark - Inputs -

- (void)activateInput:(NSInteger)gameInput value:(double)value playerIndex:(NSInteger)playerIndex
{
    self.activatedInputs |= (uint32_t)gameInput;
}

- (void)deactivateInput:(NSInteger)gameInput playerIndex:(NSInteger)playerIndex
{
    self.activatedInputs &= ~((uint32_t)gameInput);
}

- (void)resetInputs
{
    self.activatedInputs = 0;
}

#pragma mark - Game Saves -

- (void)saveGameSaveToURL:(NSURL *)URL
{
    // ROM/memory buffers are NULL when no game is loaded (Crashlytics 6626f25b).
    if (![self isGameLoaded])
    {
        return;
    }
    
    GBASystem.emuWriteBattery(URL.fileSystemRepresentation);
}

- (void)loadGameSaveFromURL:(NSURL *)URL
{
    // ROM/memory buffers are NULL when no game is loaded (Crashlytics 6626f25b).
    if (![self isGameLoaded])
    {
        return;
    }
    
    GBASystem.emuReadBattery(URL.fileSystemRepresentation);
}

#pragma mark - Save States -

- (void)saveSaveStateToURL:(NSURL *)URL
{
    // ROM/memory buffers are NULL when no game is loaded (Crashlytics 6626f25b).
    if (![self isGameLoaded])
    {
        return;
    }
    
    GBASystem.emuWriteState(URL.fileSystemRepresentation);
}

- (void)loadSaveStateFromURL:(NSURL *)URL
{
    // ROM/memory buffers are NULL when no game is loaded (Crashlytics 6626f25b).
    if (![self isGameLoaded])
    {
        return;
    }
    
    GBASystem.emuReadState(URL.fileSystemRepresentation);
}

#pragma mark - Cheats -

- (BOOL)addCheatCode:(NSString *)cheatCode type:(NSString *)type
{
    NSArray<NSString *> *codes = [cheatCode componentsSeparatedByString:@"\n"];
    for (NSString *code in codes)
    {
        NSMutableCharacterSet *legalCharactersSet = [NSMutableCharacterSet hexadecimalCharacterSet];
        [legalCharactersSet addCharactersInString:@" "];
        
        if ([code rangeOfCharacterFromSet:[legalCharactersSet invertedSet]].location != NSNotFound)
        {
            return NO;
        }
        
        if ([type isEqualToString:CheatTypeActionReplay] || [type isEqualToString:CheatTypeGameShark])
        {
            NSString *sanitizedCode = [code stringByReplacingOccurrencesOfString:@" " withString:@""];
            
            if (sanitizedCode.length != 16)
            {
                return NO;
            }
            
            cheatsAddGSACode([sanitizedCode UTF8String], "code", true);
        }
        else if ([type isEqualToString:CheatTypeCodeBreaker])
        {
            if (code.length != 13)
            {
                return NO;
            }
            
            cheatsAddCBACode([code UTF8String], "code");
        }
    }
    
    return YES;
}

- (void)resetCheats
{
    cheatsDeleteAll(true);
}

- (void)updateCheats
{
    
}

#pragma mark - Gyroscope -

- (void)activateGyroscope
{
    if ([self.motionManager isGyroActive] || ![self.motionManager isGyroAvailable])
    {
        return;
    }
    
    [self.motionManager startGyroUpdates];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:GBADidActivateGyroNotification object:self];
}

- (void)deactivateGyroscope
{
    if (![self.motionManager isGyroActive])
    {
        return;
    }
    
    [self.motionManager stopGyroUpdates];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:GBADidDeactivateGyroNotification object:self];
}

#pragma mark - Getters/Setters -

- (NSTimeInterval)frameDuration
{
    return (1.0 / 60.0);
}

@end

#pragma mark - VBA-M -

void systemMessage(int _iId, const char * _csFormat, ...)
{
    NSLog(@"VBA-M: %s", _csFormat);
}

void systemDrawScreen()
{
    // Get rid of the first line and the last row
    for (int y = 0; y < 160; y++)
    {
        memcpy([GBAEmulatorBridge sharedBridge].videoRenderer.videoBuffer + y * 240 * 4, g_pix + (y + 1) * (240 + 1) * 4, 240 * 4);
    }
    
    [[GBAEmulatorBridge sharedBridge].videoRenderer processFrame];
    [[GBAEmulatorBridge sharedBridge] setFrameReady:YES];
}

bool systemReadJoypads()
{
    return true;
}

uint32_t systemReadJoypad(int joy)
{
    return [GBAEmulatorBridge sharedBridge].activatedInputs;
}

void systemShowSpeed(int _iSpeed)
{
    
}

void system10Frames()
{
    if (systemSaveUpdateCounter > 0)
    {
        systemSaveUpdateCounter--;
        
        if (systemSaveUpdateCounter <= SYSTEM_SAVE_NOT_UPDATED)
        {
            if (GBAEmulatorBridge.sharedBridge.saveUpdateHandler)
            {
                GBAEmulatorBridge.sharedBridge.saveUpdateHandler();
            }
            
            systemSaveUpdateCounter = SYSTEM_SAVE_NOT_UPDATED;
        }
    }
}

void systemFrame()
{
    
}

void systemSetTitle(const char * _csTitle)
{

}

void systemScreenCapture(int _iNum)
{

}

uint32_t systemGetClock()
{
    timeval time;
    
    gettimeofday(&time, NULL);
    
    double milliseconds = (time.tv_sec * 1000.0) + (time.tv_usec / 1000.0);
    return milliseconds;
}

void systemSendScreen()
{
}

std::unique_ptr<SoundDriver> systemSoundInit()
{
    soundShutdown();
    
    return std::make_unique<GBASoundDriver>();
}

void systemUpdateMotionSensor()
{
}

uint8_t systemGetSensorDarkness()
{
    return 0;
}

int systemGetSensorX()
{
    return 0;
}

int systemGetSensorY()
{
    return 0;
}

int systemGetSensorZ()
{
    if (![GBAEmulatorBridge.sharedBridge.motionManager isGyroActive])
    {
        [GBAEmulatorBridge.sharedBridge activateGyroscope];
    }
    
    CMGyroData *gyroData = GBAEmulatorBridge.sharedBridge.motionManager.gyroData;
    
    int sensorZ = -gyroData.rotationRate.z * 25;
    return sensorZ;
}

void systemCartridgeRumble(bool)
{
}

void systemPossibleCartridgeRumble(bool)
{
}

void updateRumbleFrame()
{
}

void systemGbPrint(uint8_t * _puiData,
                   int  _iLen,
                   int  _iPages,
                   int  _iFeed,
                   int  _iPalette,
                   int  _iContrast)
{
}

void systemScreenMessage(const char * _csMsg)
{
}

bool systemCanChangeSoundQuality()
{
    return true;
}

bool systemPauseOnFrame()
{
    return false;
}

void systemGbBorderOn()
{
}

void systemOnSoundShutdown()
{
}

void systemOnWriteDataToSoundBuffer(const uint16_t * finalWave, int length)
{
}

void log(const char *defaultMsg, ...)
{
    // The core logs through this hook (cheats, AGB print, option changes). The old implementation
    // wrote to "trace.log" in the working directory, which does not exist on iOS.
    char buffer[1024];
    
    va_list valist;
    va_start(valist, defaultMsg);
    vsnprintf(buffer, sizeof(buffer), defaultMsg, valist);
    va_end(valist);
    
    NSLog(@"VBA-M: %s", buffer);
}
