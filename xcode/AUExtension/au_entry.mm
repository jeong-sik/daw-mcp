/**
 * Audio Unit Entry Point - IPC Mode (Objective-C++)
 *
 * AU v3 plugin for macOS. Communicates with daw-mcp server via Unix socket.
 * Lightweight C++ shim - no embedded OCaml runtime.
 *
 * Architecture:
 * [DAW] <-> [AU Plugin (this)] <-> [Unix Socket] <-> [daw-mcp MCP Server]
 *
 * Safety:
 * - ARC enabled, weak/strong dance for blocks
 * - Cancellable reconnect timer (dispatch_source)
 * - Max reconnect attempts to prevent infinite loops
 * - No blocking in render callback (real-time safe)
 * - std::shared_ptr<RenderContext> for lifetime separation
 * - Lock-free SPSC ring buffer for RT-safe parameter events
 *
 * Style:
 * - Pure functions for message construction (no side effects)
 * - Explicit state transitions via ConnectionState enum
 * - Result<T, E> pattern for error handling
 */

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudioKit/CoreAudioKit.h>
#import <CoreMIDI/CoreMIDI.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <atomic>
#include <memory>
#include <optional>
#include <string>
#include <array>

/* Configuration - Declarative constants */
namespace Config {
    constexpr const char* SOCKET_PATH = "/tmp/daw-bridge.sock";
    constexpr int RECONNECT_INTERVAL_SEC = 5;
    constexpr int MAX_RECONNECT_ATTEMPTS = 10;
    constexpr size_t JSON_BUFFER_SIZE = 4096;
    constexpr size_t RING_BUFFER_SIZE = 16;  // Power of 2 for lock-free
}

#pragma mark - Pure Functions (No Side Effects)

namespace JsonRpc {
    /**
     * Pure function: Construct JSON-RPC message
     * Input → Output, no side effects
     */
    [[nodiscard]]
    static std::string makeRequest(const char* method, const char* params = nullptr) {
        std::string result;
        result.reserve(Config::JSON_BUFFER_SIZE);

        if (params) {
            result = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"";
            result += method;
            result += "\",\"params\":";
            result += params;
            result += "}\n";
        } else {
            result = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"";
            result += method;
            result += "\"}\n";
        }
        return result;
    }

    /* Predefined messages (compile-time known) */
    [[nodiscard]]
    static std::string initializeMessage() {
        return makeRequest("initialize",
            R"({"protocolVersion":"2024-11-05","clientInfo":{"name":"DAWBridge-AU"}})");
    }

    [[nodiscard]]
    static std::string activatedMessage() {
        return makeRequest("notifications/activated");
    }

    [[nodiscard]]
    static std::string deactivatedMessage() {
        return makeRequest("notifications/deactivated");
    }

    [[nodiscard]]
    static std::string transportPlayMessage() {
        return makeRequest("tools/call", R"({"name":"transport_play"})");
    }

    [[nodiscard]]
    static std::string transportStopMessage() {
        return makeRequest("tools/call", R"({"name":"transport_stop"})");
    }
}

#pragma mark - CoreMIDI Transport (Direct DAW Control)

/**
 * MIDI Transport - Control DAW via MIDI Machine Control (MMC)
 *
 * This bypasses AppleScript entirely! Logic Pro responds to:
 * - MIDI Transport: Start (0xFA), Stop (0xFC), Continue (0xFB)
 * - MMC SysEx: Play (F0 7F 7F 06 02 F7), Stop (F0 7F 7F 06 01 F7)
 *
 * Architecture benefit: No System Events permission required!
 */
namespace MIDITransport {
    static MIDIClientRef g_midiClient = 0;
    static MIDIEndpointRef g_midiSource = 0;
    static bool g_initialized = false;

    /**
     * Initialize CoreMIDI client and virtual source
     * Called once on plugin init - creates "DAW Bridge" MIDI output
     */
    [[nodiscard]]
    static bool initialize() {
        if (g_initialized) return true;

        OSStatus status;

        // Create MIDI client
        status = MIDIClientCreate(CFSTR("DAW Bridge MCP"), nullptr, nullptr, &g_midiClient);
        if (status != noErr) {
            NSLog(@"[DAW Bridge] MIDI client creation failed: %d", (int)status);
            return false;
        }

        // Create virtual MIDI source (appears as "DAW Bridge" in MIDI setup)
        status = MIDISourceCreate(g_midiClient, CFSTR("DAW Bridge Control"), &g_midiSource);
        if (status != noErr) {
            NSLog(@"[DAW Bridge] MIDI source creation failed: %d", (int)status);
            MIDIClientDispose(g_midiClient);
            g_midiClient = 0;
            return false;
        }

        g_initialized = true;
        NSLog(@"[DAW Bridge] MIDI initialized - 'DAW Bridge Control' source available");
        return true;
    }

    /**
     * Cleanup MIDI resources
     */
    static void cleanup() {
        if (g_midiSource) {
            MIDIEndpointDispose(g_midiSource);
            g_midiSource = 0;
        }
        if (g_midiClient) {
            MIDIClientDispose(g_midiClient);
            g_midiClient = 0;
        }
        g_initialized = false;
    }

    /**
     * Send raw MIDI bytes via virtual source
     */
    static bool sendMIDI(const UInt8* data, UInt32 length) {
        if (!g_initialized || !g_midiSource) return false;

        // Build MIDI packet list
        MIDIPacketList packetList;
        MIDIPacket* packet = MIDIPacketListInit(&packetList);
        packet = MIDIPacketListAdd(&packetList, sizeof(packetList), packet,
                                    0, length, data);
        if (!packet) return false;

        OSStatus status = MIDIReceived(g_midiSource, &packetList);
        return status == noErr;
    }

    /**
     * Send MIDI Start (0xFA) - begins playback from current position
     */
    static bool sendStart() {
        const UInt8 msg[] = { 0xFA };  // MIDI Start
        return sendMIDI(msg, 1);
    }

    /**
     * Send MIDI Stop (0xFC)
     */
    static bool sendStop() {
        const UInt8 msg[] = { 0xFC };  // MIDI Stop
        return sendMIDI(msg, 1);
    }

    /**
     * Send MIDI Continue (0xFB) - resumes from current position
     */
    static bool sendContinue() {
        const UInt8 msg[] = { 0xFB };  // MIDI Continue
        return sendMIDI(msg, 1);
    }

    /**
     * Send MMC Play command (SysEx)
     * F0 7F 7F 06 02 F7 = Device: all, Command: Play
     */
    static bool sendMMCPlay() {
        const UInt8 msg[] = { 0xF0, 0x7F, 0x7F, 0x06, 0x02, 0xF7 };
        return sendMIDI(msg, 6);
    }

    /**
     * Send MMC Stop command (SysEx)
     * F0 7F 7F 06 01 F7 = Device: all, Command: Stop
     */
    static bool sendMMCStop() {
        const UInt8 msg[] = { 0xF0, 0x7F, 0x7F, 0x06, 0x01, 0xF7 };
        return sendMIDI(msg, 6);
    }

    /**
     * Send MMC Record Strobe (SysEx)
     * F0 7F 7F 06 06 F7 = Device: all, Command: Record Strobe
     */
    static bool sendMMCRecord() {
        const UInt8 msg[] = { 0xF0, 0x7F, 0x7F, 0x06, 0x06, 0xF7 };
        return sendMIDI(msg, 6);
    }

    /**
     * Send MMC Rewind (SysEx)
     * F0 7F 7F 06 05 F7 = Device: all, Command: Rewind
     */
    static bool sendMMCRewind() {
        const UInt8 msg[] = { 0xF0, 0x7F, 0x7F, 0x06, 0x05, 0xF7 };
        return sendMIDI(msg, 6);
    }

    /**
     * Send MMC Fast Forward (SysEx)
     * F0 7F 7F 06 04 F7 = Device: all, Command: Fast Forward
     */
    static bool sendMMCForward() {
        const UInt8 msg[] = { 0xF0, 0x7F, 0x7F, 0x06, 0x04, 0xF7 };
        return sendMIDI(msg, 6);
    }
}

#pragma mark - Result Type (Functional Error Handling)

template<typename T>
struct Result {
    std::optional<T> value;
    std::optional<std::string> error;

    [[nodiscard]] bool isOk() const { return value.has_value(); }
    [[nodiscard]] bool isErr() const { return error.has_value(); }

    static Result ok(T v) { return {std::move(v), std::nullopt}; }
    static Result err(std::string e) { return {std::nullopt, std::move(e)}; }
};

/* Specialization for void-like success */
struct UnitResult {
    std::optional<std::string> error;

    [[nodiscard]] bool isOk() const { return !error.has_value(); }
    [[nodiscard]] bool isErr() const { return error.has_value(); }

    static UnitResult ok() { return {std::nullopt}; }
    static UnitResult err(std::string e) { return {std::move(e)}; }
};

#pragma mark - Connection State (Explicit State Machine)

enum class ConnectionState : uint8_t {
    Disconnected,
    Connecting,
    Connected,
    Deallocating
};

#pragma mark - Lock-Free SPSC Ring Buffer (RT-Safe)

/**
 * Single-Producer Single-Consumer lock-free queue
 * Producer: Audio thread (real-time)
 * Consumer: IPC thread (non-real-time)
 *
 * No allocations, no locks - safe for audio callback
 */
enum class DAWParamEvent : uint8_t {
    None = 0,
    TransportPlay,
    TransportStop
};

template<size_t N>
class SPSCRingBuffer {
    static_assert((N & (N - 1)) == 0, "N must be power of 2");

    // Cache line size for False Sharing prevention
    // C++17 std::hardware_destructive_interference_size is not always available
    static constexpr size_t kCacheLineSize = 64;

    // Data buffer
    std::array<std::atomic<DAWParamEvent>, N> buffer_{};

    // Producer index - isolated to its own cache line
    alignas(kCacheLineSize) std::atomic<size_t> writeIdx_{0};

    // Consumer index - isolated to its own cache line
    alignas(kCacheLineSize) std::atomic<size_t> readIdx_{0};

    // Padding to prevent false sharing with subsequent members
    char padding_[kCacheLineSize - sizeof(std::atomic<size_t>)];

public:
    /**
     * Push event (Producer - Audio Thread)
     * Lock-free, wait-free, no allocation
     */
    [[nodiscard]]
    bool tryPush(DAWParamEvent event) noexcept {
        const size_t currentWrite = writeIdx_.load(std::memory_order_relaxed);
        const size_t nextWrite = (currentWrite + 1) & (N - 1);

        if (nextWrite == readIdx_.load(std::memory_order_acquire)) {
            return false;  // Buffer full
        }

        buffer_[currentWrite].store(event, std::memory_order_relaxed);
        writeIdx_.store(nextWrite, std::memory_order_release);
        return true;
    }

    /**
     * Pop event (Consumer - IPC Thread)
     * Lock-free
     */
    [[nodiscard]]
    std::optional<DAWParamEvent> tryPop() noexcept {
        const size_t currentRead = readIdx_.load(std::memory_order_relaxed);

        if (currentRead == writeIdx_.load(std::memory_order_acquire)) {
            return std::nullopt;  // Buffer empty
        }

        DAWParamEvent event = buffer_[currentRead].load(std::memory_order_relaxed);
        readIdx_.store((currentRead + 1) & (N - 1), std::memory_order_release);
        return event;
    }
};

#pragma mark - RenderContext (Shared Lifetime)

/**
 * RenderContext: Separated from ObjC object lifetime.
 * Owns the lock-free ring buffer for RT-safe parameter events.
 */
struct RenderContext {
    std::atomic<ConnectionState> state{ConnectionState::Disconnected};
    SPSCRingBuffer<Config::RING_BUFFER_SIZE> parameterEvents;

    RenderContext() = default;
    ~RenderContext() = default;

    // Non-copyable
    RenderContext(const RenderContext&) = delete;
    RenderContext& operator=(const RenderContext&) = delete;

    /* Pure query functions */
    [[nodiscard]]
    bool isConnected() const noexcept {
        return state.load(std::memory_order_acquire) == ConnectionState::Connected;
    }

    [[nodiscard]]
    bool isDeallocating() const noexcept {
        return state.load(std::memory_order_acquire) == ConnectionState::Deallocating;
    }
};

#pragma mark - Socket Operations (With Proper Error Handling)

namespace Socket {
    /**
     * Connect to Unix socket
     * Returns Result with fd or error message
     */
    [[nodiscard]]
    static Result<int> connect(const char* path) {
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) {
            return Result<int>::err("socket() failed");
        }

        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

        if (::connect(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
            close(fd);
            return Result<int>::err("connect() failed");
        }

        return Result<int>::ok(fd);
    }

    /**
     * Send all data (handles short writes)
     * Uses send() with MSG_NOSIGNAL to prevent SIGPIPE
     */
    [[nodiscard]]
    static UnitResult sendAll(int fd, const std::string& data) {
        if (fd < 0) {
            return UnitResult::err("invalid fd");
        }

        const char* ptr = data.c_str();
        size_t remaining = data.length();

        while (remaining > 0) {
            // MSG_NOSIGNAL prevents SIGPIPE on broken pipe (macOS uses SO_NOSIGPIPE instead)
            #ifdef __APPLE__
            ssize_t sent = write(fd, ptr, remaining);
            #else
            ssize_t sent = send(fd, ptr, remaining, MSG_NOSIGNAL);
            #endif

            if (sent < 0) {
                if (errno == EINTR) continue;  // Interrupted, retry
                if (errno == EAGAIN || errno == EWOULDBLOCK) continue;  // Would block, retry
                return UnitResult::err("send() failed: " + std::string(strerror(errno)));
            }
            if (sent == 0) {
                return UnitResult::err("connection closed");
            }

            ptr += sent;
            remaining -= static_cast<size_t>(sent);
        }

        return UnitResult::ok();
    }

    /**
     * Set socket options for reliability
     */
    static void configure(int fd) {
        #ifdef __APPLE__
        // Prevent SIGPIPE on macOS
        int nosigpipe = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));
        #endif

        // Set send timeout to prevent blocking forever
        struct timeval tv;
        tv.tv_sec = 1;
        tv.tv_usec = 0;
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    }
}

// Note: With Principal Class pattern, DAWBridgeViewController (in au_view_controller.mm)
// implements AUAudioUnitFactory and creates this AudioUnit. No external factory needed.

#pragma mark - AU v3 Audio Unit

@class DAWBridgeAudioUnit;

// Weak reference protocol for View Controller
@protocol DAWBridgeAudioUnitViewHolder <NSObject>
@property (nonatomic, weak, nullable) AUViewControllerBase *associatedViewController;
@end

__attribute__((visibility("default")))
@interface DAWBridgeAudioUnit : AUAudioUnit<DAWBridgeAudioUnitViewHolder> {
    int _socket_fd;
    dispatch_queue_t _ipc_queue;
    dispatch_source_t _reconnectTimer;
    dispatch_source_t _eventDrainTimer;  // Drains ring buffer periodically
    int _reconnectAttempts;

    std::shared_ptr<RenderContext> _renderContext;
    AUAudioUnitBusArray *_inputBusArray;
    AUAudioUnitBusArray *_outputBusArray;
}

// Weak reference to the view controller that created this AU (Principal Class pattern)
@property (nonatomic, weak, nullable) AUViewControllerBase *associatedViewController;

@end

@implementation DAWBridgeAudioUnit

- (instancetype)initWithComponentDescription:(AudioComponentDescription)componentDescription
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError **)outError {
    self = [super initWithComponentDescription:componentDescription options:options error:outError];
    if (self) {
        _socket_fd = -1;
        _reconnectAttempts = 0;
        _ipc_queue = dispatch_queue_create("com.dancer.daw-bridge.ipc", DISPATCH_QUEUE_SERIAL);
        _renderContext = std::make_shared<RenderContext>();

        AVAudioFormat *defaultFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100.0
                                                                                      channels:2];

        // Effect AU requires both input and output buses
        _inputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self
                                                               busType:AUAudioUnitBusTypeInput
                                                                busses:@[[[AUAudioUnitBus alloc]
                                                                          initWithFormat:defaultFormat
                                                                          error:nil]]];

        _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self
                                                                busType:AUAudioUnitBusTypeOutput
                                                                 busses:@[[[AUAudioUnitBus alloc]
                                                                           initWithFormat:defaultFormat
                                                                           error:nil]]];

        [self startEventDrainTimer];

        // Initialize MIDI transport (deferred to first use for auval compatibility)
        // MIDITransport will auto-initialize when first transport command is sent

        [self connectToServer];
    }
    return self;
}

#pragma mark - Event Drain Timer (Consumes Ring Buffer)

- (void)startEventDrainTimer {
    _eventDrainTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _ipc_queue);

    std::shared_ptr<RenderContext> ctx = _renderContext;
    __weak __typeof__(self) weakSelf = self;

    dispatch_source_set_event_handler(_eventDrainTimer, ^{
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || ctx->isDeallocating()) return;

        // Drain all pending events from ring buffer
        while (auto event = ctx->parameterEvents.tryPop()) {
            bool midiSuccess = false;
            std::string message;

            switch (*event) {
                case DAWParamEvent::TransportPlay:
                    // Lazy init MIDI on first use
                    if (MIDITransport::initialize()) {
                        midiSuccess = MIDITransport::sendStart() || MIDITransport::sendMMCPlay();
                        if (midiSuccess) {
                            NSLog(@"[DAW Bridge] MIDI Play sent");
                        }
                    }
                    message = JsonRpc::transportPlayMessage();
                    break;

                case DAWParamEvent::TransportStop:
                    // Lazy init MIDI on first use
                    if (MIDITransport::initialize()) {
                        midiSuccess = MIDITransport::sendStop() || MIDITransport::sendMMCStop();
                        if (midiSuccess) {
                            NSLog(@"[DAW Bridge] MIDI Stop sent");
                        }
                    }
                    message = JsonRpc::transportStopMessage();
                    break;

                default:
                    continue;
            }

            // Secondary: Also notify MCP server (for logging/state sync, optional)
            if (ctx->isConnected() && !message.empty()) {
                auto result = Socket::sendAll(strongSelf->_socket_fd, message);
                if (result.isErr()) {
                    NSLog(@"[DAW Bridge] Socket notify failed (MIDI already sent): %s",
                          result.error->c_str());
                }
            }
        }
    });

    // Fire every 10ms to drain events (100Hz, sufficient for transport control)
    dispatch_source_set_timer(_eventDrainTimer,
        dispatch_time(DISPATCH_TIME_NOW, 0),
        10 * NSEC_PER_MSEC,
        1 * NSEC_PER_MSEC);

    dispatch_resume(_eventDrainTimer);
}

- (void)stopEventDrainTimer {
    if (_eventDrainTimer) {
        dispatch_source_cancel(_eventDrainTimer);
        _eventDrainTimer = nil;
    }
}

#pragma mark - Connection Management

- (void)connectToServer {
    __weak __typeof__(self) weakSelf = self;

    dispatch_async(_ipc_queue, ^{
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        auto& ctx = strongSelf->_renderContext;
        if (ctx->isDeallocating() || ctx->isConnected()) return;

        if (strongSelf->_reconnectAttempts >= Config::MAX_RECONNECT_ATTEMPTS) {
            NSLog(@"[DAW Bridge] Max reconnect attempts (%d) reached", Config::MAX_RECONNECT_ATTEMPTS);
            return;
        }

        ctx->state.store(ConnectionState::Connecting, std::memory_order_release);

        auto result = Socket::connect(Config::SOCKET_PATH);
        if (result.isOk()) {
            strongSelf->_socket_fd = *result.value;
            Socket::configure(strongSelf->_socket_fd);

            ctx->state.store(ConnectionState::Connected, std::memory_order_release);
            strongSelf->_reconnectAttempts = 0;

            NSLog(@"[DAW Bridge] Connected to MCP server");

            // Send initialize message
            auto sendResult = Socket::sendAll(strongSelf->_socket_fd, JsonRpc::initializeMessage());
            if (sendResult.isErr()) {
                NSLog(@"[DAW Bridge] Initialize send failed: %s", sendResult.error->c_str());
            }
        } else {
            ctx->state.store(ConnectionState::Disconnected, std::memory_order_release);
            strongSelf->_reconnectAttempts++;

            NSLog(@"[DAW Bridge] Connection failed (attempt %d/%d): %s",
                  strongSelf->_reconnectAttempts, Config::MAX_RECONNECT_ATTEMPTS,
                  result.error->c_str());

            [strongSelf scheduleReconnect];
        }
    });
}

- (void)scheduleReconnect {
    if (_reconnectTimer) {
        dispatch_source_cancel(_reconnectTimer);
        _reconnectTimer = nil;
    }

    _reconnectTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _ipc_queue);

    __weak __typeof__(self) weakSelf = self;
    dispatch_source_set_event_handler(_reconnectTimer, ^{
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_renderContext->isDeallocating()) return;

        if (strongSelf->_reconnectTimer) {
            dispatch_source_cancel(strongSelf->_reconnectTimer);
            strongSelf->_reconnectTimer = nil;
        }

        [strongSelf connectToServer];
    });

    dispatch_source_set_timer(_reconnectTimer,
        dispatch_time(DISPATCH_TIME_NOW, Config::RECONNECT_INTERVAL_SEC * NSEC_PER_SEC),
        DISPATCH_TIME_FOREVER,
        NSEC_PER_SEC / 10);

    dispatch_resume(_reconnectTimer);
}

- (void)cancelReconnectTimer {
    if (_reconnectTimer) {
        dispatch_source_cancel(_reconnectTimer);
        _reconnectTimer = nil;
    }
}

- (void)dealloc {
    _renderContext->state.store(ConnectionState::Deallocating, std::memory_order_release);

    [self stopEventDrainTimer];
    [self cancelReconnectTimer];

    if (_socket_fd >= 0) {
        close(_socket_fd);
        _socket_fd = -1;
    }

    // Cleanup MIDI resources
    MIDITransport::cleanup();

    NSLog(@"[DAW Bridge] Audio Unit deallocated");
}

#pragma mark - AUAudioUnit Overrides

- (AUAudioUnitBusArray *)inputBusses {
    return _inputBusArray;
}

- (AUAudioUnitBusArray *)outputBusses {
    return _outputBusArray;
}

// Support any channel configuration (mono, stereo, surround)
- (NSArray<NSNumber *> *)channelCapabilities {
    // -1, -1 means "any input channels, any output channels (matched)"
    return @[@(-1), @(-1)];
}

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)outError {
    if (![super allocateRenderResourcesAndReturnError:outError]) {
        return NO;
    }

    __weak __typeof__(self) weakSelf = self;
    dispatch_async(_ipc_queue, ^{
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_renderContext->isConnected()) {
            (void)Socket::sendAll(strongSelf->_socket_fd, JsonRpc::activatedMessage());
        }
    });

    return YES;
}

- (void)deallocateRenderResources {
    __weak __typeof__(self) weakSelf = self;
    dispatch_async(_ipc_queue, ^{
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_renderContext->isConnected()) {
            (void)Socket::sendAll(strongSelf->_socket_fd, JsonRpc::deactivatedMessage());
        }
    });

    [super deallocateRenderResources];
}

- (AUInternalRenderBlock)internalRenderBlock {
    /*
     * Real-time safe render block
     * - No allocations, no locks, no syscalls
     * - Only atomic reads via RenderContext
     */
    std::shared_ptr<RenderContext> renderCtx = _renderContext;

    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *actionFlags,
                              const AudioTimeStamp *timestamp,
                              AVAudioFrameCount frameCount,
                              NSInteger outputBusNumber,
                              AudioBufferList *outputData,
                              const AURenderEvent *realtimeEventListHead,
                              AURenderPullInputBlock pullInputBlock) {

        // RT-safe status check (atomic read only)
        (void)renderCtx->isConnected();
        (void)realtimeEventListHead;
        (void)outputBusNumber;

        // Pull input from upstream (required for Effect AU)
        if (pullInputBlock) {
            AUAudioUnitStatus status = pullInputBlock(actionFlags, timestamp, frameCount, 0, outputData);
            if (status != noErr) {
                return status;
            }
        }

        // Pass-through: input is already in outputData after pullInputBlock
        // This is a utility plugin - audio passes through unchanged

        return noErr;
    };
}

- (AUParameterTree *)parameterTree {
    AUParameter *transportPlay = [AUParameterTree createParameterWithIdentifier:@"play"
                                                                           name:@"Play"
                                                                        address:0
                                                                            min:0
                                                                            max:1
                                                                           unit:kAudioUnitParameterUnit_Boolean
                                                                       unitName:nil
                                                                          flags:0
                                                                   valueStrings:nil
                                                            dependentParameters:nil];

    AUParameter *transportStop = [AUParameterTree createParameterWithIdentifier:@"stop"
                                                                            name:@"Stop"
                                                                         address:1
                                                                             min:0
                                                                             max:1
                                                                            unit:kAudioUnitParameterUnit_Boolean
                                                                        unitName:nil
                                                                           flags:0
                                                                    valueStrings:nil
                                                             dependentParameters:nil];

    AUParameterTree *tree = [AUParameterTree createTreeWithChildren:@[transportPlay, transportStop]];

    /*
     * RT-safe parameter observer:
     * Instead of dispatch_async (which allocates), push to lock-free ring buffer.
     * The event drain timer on IPC thread will consume and send.
     */
    std::shared_ptr<RenderContext> ctx = _renderContext;

    tree.implementorValueObserver = ^(AUParameter *param, AUValue value) {
        if (value <= 0.5f) return;  // Only trigger on "pressed"
        if (!ctx->isConnected()) return;

        DAWParamEvent event = DAWParamEvent::None;
        switch (param.address) {
            case 0: event = DAWParamEvent::TransportPlay; break;
            case 1: event = DAWParamEvent::TransportStop; break;
            default: return;
        }

        // RT-safe: Lock-free push, no allocation
        // Intentionally ignoring return - if buffer full, drop event (acceptable for transport)
        (void)ctx->parameterEvents.tryPush(event);
    };

    return tree;
}

#pragma mark - View Controller Support

- (void)requestViewControllerWithCompletionHandler:(void (^)(AUViewControllerBase * _Nullable))completionHandler {
    NSLog(@"[DAW Bridge] requestViewControllerWithCompletionHandler called");

    // Principal Class Pattern: Return the associated view controller
    // The host created DAWBridgeViewController first, which created this AudioUnit.
    // DAWBridgeViewController set itself as associatedViewController when creating us.
    dispatch_async(dispatch_get_main_queue(), ^{
        AUViewControllerBase *viewController = self.associatedViewController;
        NSLog(@"[DAW Bridge] returning associatedViewController: %@", viewController ? @"YES" : @"NO (Principal Class may already have it)");
        completionHandler(viewController);
    });
}

@end

/* Legacy Factory - No longer needed
 *
 * Apple AU v3 Pattern: DAWBridgeViewController (defined in au_view_controller.mm)
 * is now the principal class. It implements AUAudioUnitFactory and creates
 * DAWBridgeAudioUnit in createAudioUnitWithComponentDescription:error:.
 *
 * Info.plist factoryFunction now points to DAWBridgeViewController.
 */

/* App Extension: Registration handled by Info.plist AudioComponents
 * No registerSubclass needed - the host uses NSExtensionPrincipalClass
 * (DAWBridgeViewController) which implements AUAudioUnitFactory.
 */
