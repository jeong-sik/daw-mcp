/**
 * DAW Bridge AU View Controller
 *
 * Simple status display UI for the Audio Unit:
 * - Connection status LED (green/red)
 * - Play/Stop transport buttons
 *
 * Uses AppKit for native macOS look and feel.
 */

#import <Cocoa/Cocoa.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudioKit/CoreAudioKit.h>
#include <atomic>
#include <memory>

// Forward declaration of shared types
enum class ConnectionState : uint8_t;
struct RenderContext;

// Forward declaration of the Audio Unit class (defined in au_entry.mm)
@class DAWBridgeAudioUnit;

#pragma mark - Status LED View

@interface DAWBridgeStatusLED : NSView
@property (nonatomic, assign) BOOL connected;
@end

@implementation DAWBridgeStatusLED

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _connected = NO;
    }
    return self;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    NSRect bounds = self.bounds;
    NSRect ledRect = NSInsetRect(bounds, 2, 2);

    // Outer ring
    NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:ledRect];
    [[NSColor darkGrayColor] setStroke];
    [ring setLineWidth:1.5];
    [ring stroke];

    // Inner fill with glow effect
    NSRect innerRect = NSInsetRect(ledRect, 3, 3);
    NSBezierPath *inner = [NSBezierPath bezierPathWithOvalInRect:innerRect];

    if (_connected) {
        // Green glow for connected
        NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithRed:0.2 green:0.9 blue:0.3 alpha:1.0]
                                                             endingColor:[NSColor colorWithRed:0.1 green:0.6 blue:0.2 alpha:1.0]];
        [gradient drawInBezierPath:inner angle:90];
    } else {
        // Red for disconnected
        NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:1.0]
                                                             endingColor:[NSColor colorWithRed:0.6 green:0.1 blue:0.1 alpha:1.0]];
        [gradient drawInBezierPath:inner angle:90];
    }
}

- (void)setConnected:(BOOL)connected {
    if (_connected != connected) {
        _connected = connected;
        [self setNeedsDisplay:YES];
    }
}

@end

#pragma mark - Transport Button

@interface DAWBridgeButton : NSButton
@end

@implementation DAWBridgeButton

- (instancetype)initWithTitle:(NSString *)title target:(id)target action:(SEL)action {
    self = [super initWithFrame:NSMakeRect(0, 0, 80, 28)];
    if (self) {
        self.title = title;
        self.target = target;
        self.action = action;
        self.bezelStyle = NSBezelStyleRounded;
        self.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        self.bordered = YES;
        self.wantsLayer = YES;
        [self setTranslatesAutoresizingMaskIntoConstraints:NO];
    }
    return self;
}

@end

#pragma mark - Main View Controller

__attribute__((visibility("default")))
@interface DAWBridgeViewController : AUViewController<AUAudioUnitFactory> {
    AUAudioUnit *_audioUnit;
    DAWBridgeStatusLED *_statusLED;
    NSTextField *_statusLabel;
    DAWBridgeButton *_playButton;
    DAWBridgeButton *_stopButton;
    NSTimer *_statusTimer;
}
@end

@implementation DAWBridgeViewController

- (void)loadView {
    NSLog(@"[DAW Bridge UI] loadView called");

    // Simple absolute positioning - no AutoLayout
    NSView *containerView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
    containerView.wantsLayer = YES;
    containerView.layer.backgroundColor = [[NSColor colorWithRed:0.2 green:0.2 blue:0.25 alpha:1.0] CGColor];

    // Title - absolute position
    NSTextField *titleLabel = [NSTextField labelWithString:@"DAW Bridge 1.2"];
    titleLabel.frame = NSMakeRect(10, 70, 180, 20);
    titleLabel.font = [NSFont boldSystemFontOfSize:13];
    titleLabel.textColor = [NSColor whiteColor];
    titleLabel.alignment = NSTextAlignmentCenter;
    [containerView addSubview:titleLabel];

    // Status - absolute position
    _statusLabel = [NSTextField labelWithString:@"● Disconnected"];
    _statusLabel.frame = NSMakeRect(10, 45, 180, 18);
    _statusLabel.font = [NSFont systemFontOfSize:11];
    _statusLabel.textColor = [NSColor redColor];
    _statusLabel.alignment = NSTextAlignmentCenter;
    [containerView addSubview:_statusLabel];

    // Play button - absolute position
    _playButton = [[NSButton alloc] initWithFrame:NSMakeRect(10, 8, 85, 30)];
    _playButton.title = @"▶ Play";
    _playButton.bezelStyle = NSBezelStyleRounded;
    _playButton.target = self;
    _playButton.action = @selector(playPressed:);
    [containerView addSubview:_playButton];

    // Stop button - absolute position
    _stopButton = [[NSButton alloc] initWithFrame:NSMakeRect(105, 8, 85, 30)];
    _stopButton.title = @"■ Stop";
    _stopButton.bezelStyle = NSBezelStyleRounded;
    _stopButton.target = self;
    _stopButton.action = @selector(stopPressed:);
    [containerView addSubview:_stopButton];

    self.view = containerView;
    self.preferredContentSize = NSMakeSize(200, 100);

    NSLog(@"[DAW Bridge UI] loadView complete");
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self startStatusUpdates];
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    [self stopStatusUpdates];
}

- (void)dealloc {
    [self stopStatusUpdates];
}

#pragma mark - AUAudioUnit Connection

- (AUAudioUnit *)audioUnit {
    return _audioUnit;
}

- (void)setAudioUnit:(AUAudioUnit *)audioUnit {
    _audioUnit = audioUnit;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_audioUnit) {
            [self updateStatus];
        }
    });
}

#pragma mark - AUAudioUnitFactory (Principal Class Pattern)

/**
 * Apple AU v3 Pattern: Principal class creates the Audio Unit.
 * This is called by the host when loading the plugin.
 * The ViewController is the principal class (not a separate factory).
 */
- (AUAudioUnit *)createAudioUnitWithComponentDescription:(AudioComponentDescription)desc
                                                   error:(NSError **)error {
    NSLog(@"[DAW Bridge UI] createAudioUnitWithComponentDescription called");

    // Create the audio unit (DAWBridgeAudioUnit defined in au_entry.mm)
    Class auClass = NSClassFromString(@"DAWBridgeAudioUnit");
    if (!auClass) {
        NSLog(@"[DAW Bridge UI] ERROR: DAWBridgeAudioUnit class not found!");
        if (error) {
            *error = [NSError errorWithDomain:@"com.dancer.daw-bridge"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Audio Unit class not found"}];
        }
        return nil;
    }

    _audioUnit = [[auClass alloc] initWithComponentDescription:desc options:0 error:error];

    if (_audioUnit) {
        NSLog(@"[DAW Bridge UI] Audio Unit created successfully");

        // Set associatedViewController on the AudioUnit (Principal Class pattern)
        // This allows requestViewControllerWithCompletionHandler to return us
        if ([_audioUnit respondsToSelector:@selector(setAssociatedViewController:)]) {
            [_audioUnit performSelector:@selector(setAssociatedViewController:) withObject:self];
            NSLog(@"[DAW Bridge UI] Set associatedViewController on AudioUnit");
        }

        // If view is already loaded, connect UI to audio unit
        if (self.isViewLoaded) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateStatus];
            });
        }
    } else {
        NSLog(@"[DAW Bridge UI] ERROR: Failed to create Audio Unit");
    }

    return _audioUnit;
}

#pragma mark - Status Updates

- (void)startStatusUpdates {
    if (_statusTimer) return;

    __weak __typeof__(self) weakSelf = self;
    _statusTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                   repeats:YES
                                                     block:^(NSTimer * __unused timer) {
        [weakSelf updateStatus];
    }];
}

- (void)stopStatusUpdates {
    [_statusTimer invalidate];
    _statusTimer = nil;
}

- (void)updateStatus {
    if (!_audioUnit) {
        _statusLED.connected = NO;
        _statusLabel.stringValue = @"No Audio Unit";
        return;
    }

    // Check connection via custom property or parameter
    // For now, we'll use a simple approach - check if AU responds
    // In production, expose connection state via AU property

    // Prefer renderResourcesAllocated to avoid claiming "Connected" too early.
    BOOL isConnected = _audioUnit.renderResourcesAllocated;

    _statusLED.connected = isConnected;
    _statusLabel.stringValue = isConnected ? @"Connected" : @"Disconnected";

    _playButton.enabled = isConnected;
    _stopButton.enabled = isConnected;
}

#pragma mark - Button Actions

- (void)playPressed:(id)sender {
    if (!_audioUnit) return;

    // Find and set the "play" parameter
    AUParameter *playParam = [_audioUnit.parameterTree parameterWithAddress:0];
    if (playParam) {
        playParam.value = 1.0;
        // Reset after brief delay
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            playParam.value = 0.0;
        });
    }

    NSLog(@"[DAW Bridge UI] Play pressed");
}

- (void)stopPressed:(id)sender {
    if (!_audioUnit) return;

    // Find and set the "stop" parameter
    AUParameter *stopParam = [_audioUnit.parameterTree parameterWithAddress:1];
    if (stopParam) {
        stopParam.value = 1.0;
        // Reset after brief delay
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            stopParam.value = 0.0;
        });
    }

    NSLog(@"[DAW Bridge UI] Stop pressed");
}

@end

/* Note: Principal Class Pattern
 *
 * The host creates DAWBridgeViewController directly via the factoryFunction
 * in Info.plist. The ViewController implements AUAudioUnitFactory, so
 * createAudioUnitWithComponentDescription:error: is called automatically.
 *
 * No external factory function needed - Apple's AU v3 pattern handles this.
 */
