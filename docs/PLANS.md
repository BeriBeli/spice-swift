# SwiftSpice 设计方案

## 1. 项目定位

### 1.1 目标

实现一个不依赖 GLib 的原生 Swift SPICE 客户端协议栈，首期支持：

* TCP、TLS 和 SPICE ticket 认证
* Main Channel
* Display Channel
* Cursor Channel
* Inputs Channel
* RAW Bitmap、DRAW_COPY、DRAW_FILL、COPY_BITS
* macOS 原生显示和键鼠输入
* Swift Concurrency 原生异步 API
* 严格并发安全
* 后续扩展 LZ、GLZ、QUIC、音频、Agent、剪贴板和文件传输

SPICE 本身由多个独立 Channel 组成，并支持运行时增加和移除 Channel，因此项目应以“Session 监督多个独立 Channel”作为基本模型，而不是单一 Socket 上的传统客户端。

### 1.2 非目标

首期不追求：

* 与 `libspice-client-glib-2.0` API 或 ABI 兼容
* USB redirection
* Smartcard
* WebDAV
* Migration
* 全部图形命令
* 首版即实现真正的 GPU 零拷贝
* 纯 Swift 重写所有视频和图像 codec

### 1.3 工具链基线

建议基线：

```text
Swift:          6.3
Language Mode:  Swift 6
Build System:   Swift Package Manager
Apple Backend:  macOS
Core Platform:  macOS / Linux / Windows 可编译
```

Swift 6.3 已于 2026 年 3 月发布，并继续加强跨平台构建、C 互操作及库级性能控制；Swift 6 语言模式则提供完整的编译期数据竞争检查。

---

## 2. 总体架构

```text
┌───────────────────────────────────────────────┐
│                Application / UI               │
│ SwiftUI / AppKit / Keyboard / Clipboard       │
└──────────────────────┬────────────────────────┘
                       │ SessionEvent
┌──────────────────────▼────────────────────────┐
│                  SwiftSpice                    │
│ Public facade: SpiceSession, SessionOptions   │
└──────────────────────┬────────────────────────┘
                       │
┌──────────────────────▼────────────────────────┐
│                 SpiceCore                     │
│ Session supervisor / channel factory / state  │
└───────────┬──────────────┬──────────────┬─────┘
            │              │              │
       MainChannel    DisplayChannel  Inputs/Cursor
            │              │              │
┌───────────▼──────────────▼──────────────▼─────┐
│               Channel Runtime                 │
│ handshake / framing / ACK / capabilities      │
└──────────────────────┬────────────────────────┘
                       │
┌──────────────────────▼────────────────────────┐
│                SpiceTransport                 │
│ TCP / TLS / Unix socket / WebSocket           │
└───────────────────────────────────────────────┘

Display path:

DisplayChannel
      │
      ▼
ImageDecoder ──────── LZ / GLZ / QUIC / JPEG
      │
      ▼
SurfaceStore Actor
      │
      ▼
FrameSnapshot
      │
      ▼
@MainActor Presentation / Metal View
```

---

## 3. Swift Package 模块设计

```text
SwiftSpice/
├── Package.swift
├── Sources/
│   ├── SwiftSpice/
│   │   └── Public facade
│   │
│   ├── SpiceProtocol/
│   │   ├── Generated messages
│   │   ├── Message IDs
│   │   ├── Channel types
│   │   ├── Capabilities
│   │   └── Geometry/pixel formats
│   │
│   ├── SpiceWire/
│   │   ├── MessageFramer
│   │   ├── ByteReader
│   │   ├── ByteWriter
│   │   ├── AddressResolver
│   │   └── HeaderMode
│   │
│   ├── SpiceTransport/
│   │   └── Transport protocols
│   │
│   ├── SpiceTransportNetwork/
│   │   └── Apple Network.framework backend
│   │
│   ├── SpiceTransportNIO/
│   │   └── Optional cross-platform backend
│   │
│   ├── SpiceCore/
│   │   ├── SpiceSession
│   │   ├── ChannelConnection
│   │   ├── ChannelFactory
│   │   └── SessionSupervisor
│   │
│   ├── SpiceChannels/
│   │   ├── MainChannel
│   │   ├── DisplayChannel
│   │   ├── InputsChannel
│   │   ├── CursorChannel
│   │   ├── PlaybackChannel
│   │   └── AgentChannel
│   │
│   ├── SpiceCodecs/
│   │   ├── RawBitmapDecoder
│   │   ├── LZDecoder
│   │   ├── GLZDecoder
│   │   ├── QUICDecoder
│   │   └── JPEGDecoder
│   │
│   ├── SpiceRenderer/
│   │   ├── SurfaceStore
│   │   ├── DrawCommandExecutor
│   │   ├── ImageCache
│   │   └── FramePool
│   │
│   ├── SpiceApple/
│   │   ├── SpiceView
│   │   ├── MetalPresenter
│   │   ├── KeyboardMapper
│   │   └── ClipboardBridge
│   │
│   └── SpiceTestSupport/
│       ├── Packet fixtures
│       ├── FakeTransport
│       └── GoldenFrame
│
├── Plugins/
│   └── SpiceProtocolGenerator/
│
└── Tests/
    ├── SpiceWireTests/
    ├── SpiceChannelTests/
    ├── SpiceCodecTests/
    ├── SpiceIntegrationTests/
    └── SpiceFuzzTests/
```

### 依赖规则

```text
SpiceProtocol
      ▲
      │
SpiceWire ◀── SpiceCodecs
      ▲
      │
SpiceTransport
      ▲
      │
SpiceCore
      ▲
      │
SpiceChannels
      ▲
      │
SpiceRenderer
      ▲
      │
SpiceApple
```

下层模块不得导入上层模块。

---

## 4. 并发模型

## 4.1 一个 Session actor

`SpiceSession` 只负责：

* Session 生命周期
* Main Channel bootstrap
* Channel 创建和销毁
* 全局连接状态
* 错误传播
* 对外事件流

```swift
public actor SpiceSession {
    public nonisolated let events: AsyncStream<SessionEvent>

    private var state: SessionState = .idle
    private var channels: [
        ChannelKey: any SpiceChannel
    ] = [:]

    public init(options: SessionOptions)

    public func run(
        endpoint: SpiceEndpoint,
        credentials: SpiceCredentials?
    ) async throws(SpiceError)

    public func requestDisconnect() async
}
```

`run()` 是一个长生命周期函数。应用层决定其 Task 生命周期：

```swift
let session = SpiceSession(options: options)

let sessionTask = Task {
    try await session.run(
        endpoint: endpoint,
        credentials: credentials
    )
}

// Disconnect:
sessionTask.cancel()
```

库内部不应把整个生命周期隐藏在不可管理的 detached task 中。

## 4.2 每个 Channel 一个 actor

```swift
public protocol SpiceChannel: Actor {
    nonisolated var key: ChannelKey { get }

    func run() async throws(ChannelError)
    func shutdown() async
}
```

实现：

```swift
public actor DisplayChannel: SpiceChannel {
    public nonisolated let key: ChannelKey

    private let connection: ChannelConnection
    private let surfaces: SurfaceStore
    private var state: DisplayChannelState = .initializing

    public func run() async throws(ChannelError) {
        while !Task.isCancelled {
            let message = try await connection.receive()
            try await handle(message)
        }
    }
}
```

这种设计有几个重要性质：

* 同一个 Channel 内消息按协议顺序处理。
* 不同 Channel 可以并发执行。
* Display 的共享状态不需要锁。
* Inputs 发送不会阻塞 Main Channel。
* Channel 崩溃可以向 Session supervisor 汇报。

Rust `spice-client` 已经采用 Main 和 Display 独立任务的方向，但目前顶层保存一组 `JoinHandle`，并且自动连接路径主要只创建 Display Channel。Swift 版本应改为统一 Channel Factory，并让任务组负责取消和错误传播。

## 4.3 结构化并发监督

```swift
private func runChannels(
    _ channels: [any SpiceChannel]
) async throws(SpiceError) {
    do {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for channel in channels {
                group.addTask(
                    name: "SPICE \(channel.key)"
                ) {
                    try await channel.run()
                }
            }

            try await group.waitForAll()
        }
    } catch let error as ChannelError {
        throw .channel(error)
    } catch {
        throw .internalFailure(String(describing: error))
    }
}
```

设计规则：

* 禁止在消息处理过程中随意 `Task.detached`。
* 一个 Channel 只有一个 read loop。
* 一个 Channel 的发送由其 actor 串行化。
* Session 被取消时，所有 Channel 子任务一起取消。
* 任意关键 Channel 异常时，整个 Session 进入 stopping 状态。

## 4.4 控制 actor reentrancy

Actor 方法在 `await` 时可以重入，因此不要写：

```swift
state = .authenticating
let response = try await transport.read()
state = .ready
```

同时允许其他方法无条件修改 `state`。

应采用：

```swift
let generation = connectionGeneration
state = .authenticating

let response = try await transport.readExactly(...)

guard
    connectionGeneration == generation,
    state == .authenticating
else {
    throw .staleOperation
}

state = .ready
```

或者让 handshake 在一个内部不可重入流程中完成，并在 ready 之后才公开 Channel。

---

## 5. Rust 设计到 Swift 6 的映射

| Rust `spice-client`  | Swift 6 方案                        |
| -------------------- | --------------------------------- |
| `SpiceClient`        | `SpiceSession` actor              |
| `Box<dyn Transport>` | `any SpiceTransport`              |
| Tokio task           | Swift `TaskGroup`                 |
| `Arc`                | actor 或不可变 `Sendable` value       |
| callback             | `AsyncStream`                     |
| `Vec<u8>`            | `Data`、`Span`、专用 storage          |
| `HashMap`            | `Dictionary`                      |
| `binrw`              | 生成式 decoder/encoder               |
| Mutex                | actor isolation                   |
| `Result<T, E>`       | typed throws                      |
| ownership/move       | `borrowing`、`consuming`、`sending` |
| RAII resource        | `~Copyable` struct + `deinit`     |

Rust 版本的 `ChannelConnection` 已经包含 transport、channel type、connection ID、serial、handshake 状态和 capability，这个边界值得保留。

但 Swift 版本应进一步拆分为：

```text
ChannelConnection
├── Transport
├── MessageFramer
├── LinkStateMachine
├── CapabilityNegotiator
├── SerialGenerator
└── AckController
```

不要让一个大类同时承担所有解析和 Channel 业务逻辑。

---

## 6. 二进制协议层

## 6.1 不直接映射 C struct

禁止：

```swift
let value = bytes.load(as: SpiceDataHeader.self)
```

原因包括：

* 网络数据可能未对齐
* packed C struct 与 Swift layout 不一致
* 相对 offset 和变长数组无法自然映射
* 容易产生越界访问
* 不利于 fuzz testing

所有字段必须显式按小端读取：

```swift
struct ByteReader {
    private let data: Data
    private var offset: Int = 0

    mutating func readUInt16LE() throws(WireError) -> UInt16
    mutating func readUInt32LE() throws(WireError) -> UInt32
    mutating func readUInt64LE() throws(WireError) -> UInt64

    mutating func readBytes(
        count: Int
    ) throws(WireError) -> Data
}
```

## 6.2 使用 Span 处理热路径

Swift 6.2 引入了 `Span`、`RawSpan`、`MutableSpan` 和 `InlineArray`。`Span` 是具有生命周期和边界检查的非拥有内存视图，适合协议解析和 codec 内部热路径；`InlineArray` 适合固定大小 header、临时像素和小型 lookup table。

建议分两级 API：

```text
安全普通路径：
Data → ByteReader → Message

高性能内部路径：
RawSpan → SpanByteReader → Message
```

固定长度数据可使用：

```swift
struct LinkHeaderBuffer {
    var bytes: [16 of UInt8]
}

struct MiniHeaderBuffer {
    var bytes: [6 of UInt8]
}
```

`Span` 只能在同步解析作用域中使用，不应保存到 actor 属性或异步闭包中。

## 6.3 HeaderMode 必须成为连接状态

```swift
enum HeaderMode: Sendable {
    case full
    case mini
}
```

```swift
struct MessageFramer {
    let mode: HeaderMode

    mutating func append(_ bytes: Data)
    mutating func nextMessage() throws(WireError) -> FramedMessage?
}
```

Rust 实现当前仍有 Mini Header 尚未启用的 TODO；Swift 实现应从第一阶段就让 full/mini header 共用同一个 framing 层。

## 6.4 SPICE 地址解析

SPICE 的地址字段通常是相对于当前消息 body 起始位置的 offset，不能当作本地指针。

```swift
struct SpiceAddressResolver {
    let messageSize: Int

    func resolve(
        _ address: UInt64,
        minimumSize: Int
    ) throws(WireError) -> Range<Int>
}
```

必须检查：

* `address <= messageSize`
* `address + size` 是否溢出
* Range 是否位于当前消息内
* encoded address 是否被当前消息类型允许
* cache/surface 引用是否合法

---

## 7. 协议代码生成

不建议手写数百个消息类型。

建议建立 SwiftPM build tool plugin：

```text
spice protocol definitions
          │
          ▼
SpiceProtocolGenerator
          │
          ├── Enums.generated.swift
          ├── Messages.generated.swift
          ├── Capabilities.generated.swift
          ├── ClientDispatch.generated.swift
          └── ServerDispatch.generated.swift
```

生成的类型只包含：

* 字段定义
* 静态消息 ID
* decode
* encode
* 最小长度
* offset 元数据
* capability 要求

生成示例：

```swift
public struct SpiceMsgSetAck: Sendable {
    public static let messageID: UInt16 = 3
    public static let minimumWireSize = 8

    public let generation: UInt32
    public let window: UInt32

    public static func decode(
        from reader: inout ByteReader
    ) throws(WireError) -> Self {
        Self(
            generation: try reader.readUInt32LE(),
            window: try reader.readUInt32LE()
        )
    }
}
```

原则：

* 生成代码可读、可调试。
* CI 中重新生成并检查 git diff。
* 业务逻辑不得放进 generated 文件。
* wire schema 与业务类型分离。
* 未知消息不能触发 `fatalError`。

---

## 8. 类型安全的 Capability

不要使用裸 `UInt32` 到处位运算：

```swift
public protocol SpiceCapability:
    RawRepresentable,
    Sendable
where RawValue == Int {}

public struct CapabilitySet<C: SpiceCapability>: Sendable {
    private var words: [UInt32]

    public func contains(_ capability: C) -> Bool
}
```

```swift
enum CommonCapability: Int, SpiceCapability {
    case protocolAuthSelection
    case authSpice
    case authSasl
    case miniHeader
}

enum DisplayCapability: Int, SpiceCapability {
    case sizedStream
    case monitorsConfig
    case composite
    case multiCodec
    case codecMJPEG
}
```

这样可以在编译期阻止把 Display capability 传给 Main Channel。

---

## 9. 状态机设计

## 9.1 Session 状态

```swift
enum SessionState: Sendable, Equatable {
    case idle
    case connecting
    case authenticating
    case discoveringChannels
    case running(SessionID)
    case stopping
    case stopped
}
```

## 9.2 Channel 连接状态

```swift
enum ChannelConnectionState: Sendable {
    case created
    case transportConnecting
    case linkNegotiating
    case authenticating
    case ready(NegotiatedCapabilities)
    case closing
    case closed
}
```

## 9.3 Main Channel 状态

```swift
enum MainChannelState: Sendable {
    case waitingForInit
    case initialized(MainInit)
    case agentDisconnected
    case agentConnected(AgentInfo)
}
```

所有状态转换集中处理：

```swift
mutating func transition(
    on event: LinkEvent
) throws(LinkError)
```

非法的服务端状态转换应抛出协议错误，而不是使用 `preconditionFailure`。

---

## 10. Typed throws 错误模型

Swift 6 支持 typed throws，函数可以明确声明唯一的错误类型。

分层定义：

```swift
public enum TransportError: Error, Sendable {
    case connectionFailed
    case connectionClosed
    case timeout
    case tlsFailure(String)
    case cancelled
}

public enum WireError: Error, Sendable {
    case truncated
    case invalidMagic(UInt32)
    case invalidSize(Int)
    case integerOverflow
    case invalidOffset(UInt64)
    case unsupportedMessage(UInt16)
}

public enum AuthenticationError: Error, Sendable {
    case rejected
    case invalidPublicKey
    case encryptionFailed
    case unsupportedMethod
}

public enum ChannelError: Error, Sendable {
    case transport(TransportError)
    case wire(WireError)
    case authentication(AuthenticationError)
    case invalidState
    case unsupportedCapability
}

public enum SpiceError: Error, Sendable {
    case channel(ChannelError)
    case sessionRejected
    case requiredChannelMissing
    case internalFailure(String)
}
```

API：

```swift
func receive() async throws(ChannelError) -> FramedMessage

func decode(
    _ message: FramedMessage
) throws(WireError) -> ServerMessage

func run() async throws(SpiceError)
```

底层不直接抛出 `NSError` 或 `any Error`，必须在模块边界转换。

---

## 11. 所有权与 `~Copyable`

Swift 非复制类型可以表达唯一资源所有权，并通过 `borrowing`、`consuming` 及 `deinit` 管理资源生命周期。

适合使用 `~Copyable` 的对象：

* Surface 写锁
* 映射后的 framebuffer
* 临时 codec context
* 文件描述符
* C/Rust codec handle
* 一次性 authentication secret
* 一次性 frame submission token

示例：

```swift
struct SurfaceWriteLease: ~Copyable {
    private let storage: SurfaceStorage
    let bytes: MutableRawBufferPointer

    init(
        storage: SurfaceStorage,
        bytes: MutableRawBufferPointer
    ) {
        self.storage = storage
        self.bytes = bytes
    }

    deinit {
        storage.finishWrite()
    }
}
```

调用：

```swift
func execute(
    _ command: DrawCommand,
    on lease: borrowing SurfaceWriteLease
) throws(RenderError)
```

提交所有权：

```swift
func submit(
    _ frame: consuming DecodedFrame
) async
```

设计边界：

* 普通协议值保持 copyable value type。
* 不要为了“高级”而把所有消息都做成 `~Copyable`。
* 只对真正具有唯一生命周期的资源使用非复制类型。

---

## 12. `Sendable` 和 `sending`

Swift 6 的 `sending` 可以表达一个值在跨隔离域后不再被调用方使用；它与普通的“类型永久符合 Sendable”不同。

适合场景：

```swift
actor SurfaceStore {
    func install(
        _ image: sending DecodedImage
    ) {
        // image ownership is transferred here.
    }
}
```

```swift
@MainActor
func publish(
    _ snapshot: sending FrameSnapshot
) {
    // Caller must not continue mutating snapshot.
}
```

规则：

* 小型不可变消息类型直接声明 `Sendable`。
* 新创建且只需转移一次的缓冲区可使用 `sending`。
* 不要使用 `@unchecked Sendable` 掩盖设计问题。
* 所有 `@unchecked Sendable` 必须放入单独的 `UnsafeInterop` 模块。
* Core、Wire、Channels 三层目标是零 `@unchecked Sendable`。

---

## 13. Display Pipeline

## 13.1 第一版采用串行语义

Display Channel 的协议顺序可能影响：

* surface 内容
* image cache
* palette cache
* GLZ dictionary
* COPY_BITS source
* clip region
* stream 状态

所以第一版必须：

```text
Receive
  → Decode command
  → Decode image
  → Execute draw
  → Mark dirty region
  → Publish update
```

按消息顺序串行执行。

不要一开始就把所有图片解码并行化。

## 13.2 可并行任务分类

后续只有满足依赖条件时才并行：

| 操作                  | 可否并行     |
| ------------------- | -------- |
| 独立 RAW image decode | 可以       |
| 独立 JPEG decode      | 可以       |
| QUIC 独立图像           | 通常可以     |
| GLZ 使用共享字典          | 不可随意并行   |
| 同一 Surface 重叠区域     | 不可并行     |
| 不同 Surface 且无缓存依赖   | 可以       |
| COPY_BITS           | 必须保证读写顺序 |
| Cursor decode       | 可独立      |

## 13.3 使用 `@concurrent` 隔离重计算

Swift 6.2 提供 `@concurrent`，用于明确让异步函数在并发执行器上运行，而不是继承调用方的 actor。

```swift
struct JPEGDecoder {
    @concurrent
    func decode(
        _ payload: Data
    ) async throws(CodecError) -> DecodedImage {
        // CPU intensive work
    }
}
```

不过：

* GLZ dictionary decoder 应保持 actor isolation。
* 小型 RAW decode 不需要创建并发任务。
* 并行化阈值应根据 payload 大小决定。
* 禁止每个 draw command 创建一个 Task。

## 13.4 SurfaceStore

```swift
public actor SurfaceStore {
    private var surfaces: [
        SurfaceID: Surface
    ] = [:]

    func create(_ descriptor: SurfaceDescriptor)
        throws(RenderError)

    func destroy(_ id: SurfaceID)

    func execute(
        _ command: DrawCommand
    ) throws(RenderError)

    func snapshot(
        surfaceID: SurfaceID,
        dirtyRegion: SpiceRegion
    ) -> FrameSnapshot
}
```

DisplayChannel 负责协议，SurfaceStore 负责像素状态，两者不要合并成一个巨型 actor。

---

## 14. Frame 输出与 UI 隔离

## 14.1 MVP

第一版使用不可变快照：

```swift
public struct FrameSnapshot: Sendable {
    public let width: Int
    public let height: Int
    public let stride: Int
    public let format: PixelFormat
    public let pixels: Data
    public let dirtyRegion: SpiceRegion
    public let generation: UInt64
}
```

通过事件发送：

```swift
enum SessionEvent: Sendable {
    case connected(SessionInfo)
    case disconnected(DisconnectReason)
    case frame(FrameSnapshot)
    case cursor(CursorSnapshot)
    case mouseModeChanged(MouseMode)
    case clipboard(ClipboardPayload)
}
```

## 14.2 帧事件要允许合并

控制事件不能丢：

```text
connected
disconnected
keyboard state
clipboard
channel error
```

帧更新可以合并：

```text
frame generation 100
frame generation 101
frame generation 102
```

UI 来不及消费时只保留 102。

因此最好拆成两个流：

```swift
let controlEvents: AsyncStream<ControlEvent>
let frames: AsyncStream<FrameSnapshot>
```

帧流使用 `.bufferingNewest(1)`，控制流使用有界但不静默丢弃的策略。

## 14.3 后续零拷贝

后续升级为：

```text
Triple-buffered IOSurface pool
        │
        ├── write lease
        ├── committed read lease
        └── presentation lease
```

严格保证：

* UI 读取时 decoder 不写入同一 buffer。
* buffer 只有在 read lease 释放后才能回收。
* generation 匹配后才能显示。
* C/Objective-C 对象的 `@unchecked Sendable` 封装集中审计。

`@MainActor` 只负责：

* SwiftUI/AppKit 状态
* 输入事件采集
* view invalidation
* texture presentation

不得在 MainActor 上执行：

* Socket 读取
* 协议解析
* 图像解压
* framebuffer 合成
* GLZ dictionary 更新

---

## 15. Transport 设计

```swift
public nonisolated protocol SpiceTransport: Sendable {
    func connect() async throws(TransportError)

    func read(
        minimum: Int,
        maximum: Int
    ) async throws(TransportError) -> Data

    func write(
        _ data: sending Data
    ) async throws(TransportError)

    func close() async
}
```

### Apple 平台

若最低系统为 macOS 26，可优先采用新的 `NetworkConnection`，它是面向 Swift structured concurrency 设计的 Network.framework API。若需要兼容更早 macOS，则实现 `NWConnection` adapter。

```text
SpiceTransportNetwork
├── NetworkConnection backend   macOS 26+
└── NWConnection backend        older systems
```

### 跨平台

```text
SpiceTransportNIO
├── TCP
├── TLS
└── Unix domain socket
```

Core 不能依赖 Network.framework 或 SwiftNIO。

---

## 16. 认证和敏感数据

```swift
public struct SpiceCredentials: ~Copyable {
    private var passwordBytes: Data

    consuming func takePassword() -> Data

    deinit {
        passwordBytes.resetBytes(
            in: passwordBytes.indices
        )
    }
}
```

认证流程：

```text
Link message
    ↓
Link reply + public key
    ↓
Authentication method selection
    ↓
RSA-OAEP encrypted ticket
    ↓
Link result
```

安全要求：

* 日志中禁止输出 password、ticket 和完整 public key。
* 认证数据使用后主动清理。
* TLS trust policy 由调用方配置。
* 不允许默认跳过证书校验。
* 测试模式的 insecure policy 必须使用明显类型名。

```swift
enum TLSTrustPolicy: Sendable {
    case system
    case pinnedCertificate(Data)
    case pinnedPublicKey(Data)
    case insecureForTestingOnly
}
```

---

## 17. Channel Factory

```swift
struct ChannelFactory {
    func makeChannel(
        descriptor: ChannelDescriptor,
        session: SessionContext
    ) async throws(ChannelError) -> any SpiceChannel {
        switch descriptor.type {
        case .main:
            MainChannel(...)

        case .display:
            DisplayChannel(...)

        case .inputs:
            InputsChannel(...)

        case .cursor:
            CursorChannel(...)

        case .playback:
            PlaybackChannel(...)

        case .record:
            RecordChannel(...)

        case .smartcard, .usbRedir, .webdav:
            UnsupportedChannel(descriptor: descriptor)

        case .unknown:
            UnsupportedChannel(descriptor: descriptor)
        }
    }
}
```

Rust 实现当前顶层对非 Display Channel 主要采取忽略策略；Swift 版本应保留未知 Channel 描述，并产生明确的 capability/unsupported 事件。

---

## 18. 输入通道设计

输入事件用不可变值：

```swift
enum InputEvent: Sendable {
    case keyDown(scanCode: UInt32)
    case keyUp(scanCode: UInt32)
    case mouseMotion(dx: Int32, dy: Int32)
    case mousePosition(x: Int32, y: Int32, displayID: UInt8)
    case mousePress(MouseButton)
    case mouseRelease(MouseButton)
}
```

规则：

* 键盘事件绝不能合并或丢弃。
* Mouse motion 可以合并。
* Button 事件保持严格顺序。
* Client mouse 与 server mouse 分开建模。
* AppKit keyCode 不应直接进入协议层。
* 建立独立的 HID/scancode 映射模块。

```text
NSEvent
  → PhysicalKey
  → PC scan code
  → SPICE input message
```

---

## 19. Codec 策略

### 第一阶段

```text
RAW Bitmap: Swift
JPEG:       ImageIO 或轻量 C backend
LZ:         Rust/C 临时 backend
GLZ:        Rust/C 临时 backend
QUIC:       Rust/C 临时 backend
```

### Codec 接口

```swift
public nonisolated protocol SpiceImageDecoder: Sendable {
    var format: SpiceImageFormat { get }

    func decode(
        descriptor: ImageDescriptor,
        payload: Data
    ) async throws(CodecError) -> DecodedImage
}
```

### Rust bridge

Rust 仅暴露 C ABI：

```c
int spice_quic_decode(
    const uint8_t *input,
    size_t input_size,
    uint8_t *output,
    size_t output_size,
    struct SpiceDecodeInfo *info
);
```

Swift 6.3 的 `@c` 可以用于从 Swift 暴露稳定 C entry point，但核心 Swift API 不应设计成 C 风格。

互操作隔离：

```text
SpiceCodecs
    ▲
    │ safe Swift protocol
SpiceCodecInterop
    ▲
    │ audited unsafe boundary
Rust/C static libraries
```

所有 unsafe pointer、C handle 和 `@unchecked Sendable` 都集中在 `SpiceCodecInterop`。

---

## 20. 性能设计原则

### 20.1 首先消除架构性拷贝

重点观察：

```text
Network receive
→ framing buffer
→ message body
→ codec input
→ decoded pixels
→ surface
→ UI frame
```

目标：

* framing 阶段最多一次拼接
* codec 输入不复制
* decoded image 到 surface 最多一次复制
* dirty region 只复制变化区域
* UI 落后时不积累旧帧

### 20.2 不预先使用危险优化

禁止在没有 benchmark 前使用：

* 到处 `@inline(__always)`
* 到处 `withUnsafeBytes`
* 手写未对齐 load
* 全局共享 buffer pool
* 无约束并行 decode
* 巨大的 `@unchecked Sendable` wrapper

Swift 6.3 提供 `@specialize` 和更明确的 inlining 控制，但应该只在性能测试证明有收益后使用。

### 20.3 推荐性能指标

* handshake 总耗时
* 每个 Channel 建立耗时
* message framing throughput
* allocations/message
* codec decode time
* draw command execution time
* frame publish latency
* dropped/coalesced frame 数
* 输入事件发送延迟
* peak surface memory
* image cache hit rate
* GLZ dictionary hit rate

---

## 21. 安全限制

所有来自服务端的长度都不可信。

```swift
struct ProtocolLimits: Sendable {
    let maximumMessageSize: Int
    let maximumSurfaceWidth: Int
    let maximumSurfaceHeight: Int
    let maximumSurfaceBytes: Int
    let maximumImageBytes: Int
    let maximumDecompressedBytes: Int
    let maximumChannels: Int
    let maximumCacheEntries: Int
}
```

每次分配前执行：

```swift
let (pixels, overflow1) =
    width.multipliedReportingOverflow(by: height)

let (bytes, overflow2) =
    pixels.multipliedReportingOverflow(by: bytesPerPixel)

guard !overflow1, !overflow2 else {
    throw WireError.integerOverflow
}
```

必须防御：

* 巨型消息
* width × height 溢出
* 负数转换成超大无符号数
* 解压炸弹
* 循环 cache 引用
* 越界 SpiceAddress
* 无效 stride
* 重复 surface ID
* 未知 codec
* ACK window 为零或异常大
* 恶意频繁创建和销毁 Surface

建议对 Wire 和 Codec target 启用 Swift 6.2 的严格内存安全检查，并显式标注确实需要的 unsafe 操作。

---

## 22. 测试设计

## 22.1 Wire 单元测试

每个 message 至少有：

* 正常 decode
* 正常 encode
* encode/decode round trip
* 少一个字节
* 错误 size
* 最大值
* offset 越界
* 整数溢出
* 未知 enum
* trailing bytes

## 22.2 参数化测试

```swift
@Test(arguments: messageFixtures)
func decodeFixture(
    fixture: MessageFixture
) throws {
    let message = try decoder.decode(fixture.bytes)
    #expect(message == fixture.expected)
}
```

## 22.3 Differential testing

同一输入分别交给：

* Swift decoder
* Rust `spice-client` 或 Capsaicin decoder
* `spice-gtk` 参考实现

比较：

* 消息字段
* 解码像素
* Surface checksum
* dirty region
* cache 状态
* 错误分类

## 22.4 Golden frame

保存协议消息序列，而不只保存最终 PNG：

```text
fixture/
├── messages.bin
├── metadata.json
├── expected-frame.png
└── expected-hash.txt
```

测试应从初始空 Surface 重放消息，比较最终 framebuffer。

Swift 6.3 的 Swift Testing 支持图像附件，可在 golden frame 失败时附加实际输出、预期输出和差异图。

## 22.5 Fuzzing

重点 fuzz：

* Link reply
* Full header
* Mini header
* SpiceAddress
* image descriptor
* clip rect
* LZ/GLZ/QUIC decoder
* Display command dispatch
* Agent message framing

Fuzzer 的基本不变量：

```text
输入可以失败
输入不能 crash
输入不能无限循环
输入不能越界
输入不能申请无界内存
输入不能留下半更新 Surface
```

## 22.6 FakeTransport

```swift
actor FakeTransport: SpiceTransport {
    private var inbound: [Data]
    private(set) var outbound: [Data] = []

    func read(...) async throws(TransportError) -> Data
    func write(_ data: sending Data) async throws(TransportError)
}
```

使用它精确测试：

* 分片读取
* header 与 body 分离
* 一个 read 返回多个 message
* 连接中途关闭
* 延迟
* 认证失败
* Channel cancellation

---

## 23. 日志与诊断

使用结构化日志分类：

```text
com.example.swiftspice.transport
com.example.swiftspice.session
com.example.swiftspice.channel.main
com.example.swiftspice.channel.display
com.example.swiftspice.codec
com.example.swiftspice.renderer
```

日志字段：

```text
session_id
channel_type
channel_id
message_id
message_size
serial
surface_id
stream_id
codec
duration
```

禁止记录：

```text
password
ticket
clipboard 内容
文件内容
完整 framebuffer
认证 token
```

提供可选 protocol trace：

```swift
struct TraceEvent: Sendable {
    let direction: Direction
    let channel: ChannelKey
    let messageID: UInt16
    let payloadSize: Int
    let timestamp: ContinuousClock.Instant
}
```

---

## 24. 分阶段实现

### 阶段 A：协议基础设施

完成：

* Package 拆分
* ByteReader/Writer
* Span fast path
* Full/Mini framer
* 协议代码生成器
* CapabilitySet
* FakeTransport
* Wire fuzz tests

验收：

* 无并发警告
* 无不受控 unsafe pointer
* 所有基础消息支持 truncated-input 测试

### 阶段 B：连接与 Main Channel

完成：

* TCP
* TLS
* Link handshake
* ticket authentication
* Main Init
* Channel List
* Ping/Pong
* ACK flow control
* Session actor
* Channel Factory

验收：

* 能与 QEMU SPICE Server 建立 Session
* 能正确发现所有 Channel
* cancellation 能关闭全部连接

### 阶段 C：基础桌面

完成：

* Display surface create/destroy
* RAW bitmap
* DRAW_COPY
* DRAW_FILL
* COPY_BITS
* Inputs
* Cursor
* AppKit/SwiftUI view
* Frame coalescing

验收：

* 能显示 guest 桌面
* 键鼠可用
* 窗口持续缩放不会阻塞 Channel
* UI 卡顿不会造成无界帧积压

### 阶段 D：压缩

顺序：

1. JPEG
2. LZ
3. QUIC
4. image cache
5. GLZ
6. GLZ dictionary
7. MJPEG stream

验收：

* 与 Rust/C 参考 decoder 像素级一致
* malformed input 不 crash
* codec 错误不会污染当前 Surface

### 阶段 E：桌面集成

完成：

* Agent
* clipboard
* dynamic resolution
* multiple monitors
* playback
* record
* file transfer

### 阶段 F：高级能力

完成：

* H.264/H.265
* IOSurface frame pool
* Metal renderer
* migration
* smartcard
* USB redirection
* WebDAV

当前进度：已完成有界 H.264/H.265 Annex-B 解析、参数集积累、CoreMedia 长度
前缀转换、隔离的 VideoToolbox decoder actor、NV12 到 BGRA 转换，以及 Display
stream 生命周期接入。FFmpeg 软件参考 corpus 已覆盖 H.264 High、Baseline 参数集
切换和 H.265 Main，真实 VideoToolbox 输出通过本地门槛。由于仍没有可用的真实
SPICE listener，客户端继续只协商 MJPEG；`CODEC_H264`/`CODEC_H265` capability
必须在对应联调门槛关闭后逐项打开。IOSurface frame pool 第一片也已完成：独立
interop target 提供按几何与 BGRA 像素格式分桶的三缓冲池，以 frame/byte 双重上限
约束分配，并通过不可变 read lease 阻止仍在消费的 surface 被复用。池耗尽时
SurfaceStore 无阻塞地保留 `Data` 快照 fallback。Metal presenter 第一片也已接入
`SpiceDesktopView`：私有 `MTKView` 将 IOSurface BGRA 映射为 texture 并 blit 到
drawable，command-buffer completion 持有 frame lease，CPU-only frame 继续走
AppKit/CGImage，游标由两条路径共享的透明 AppKit overlay 合成。真实 GPU 测试已
验证 texture 映射和 byte-exact blit。新增 `spice-viewer` SwiftPM GUI executable、
可生成真实 `.app` bundle 的统一 build/run 脚本和 Codex Run action；合成 640×360
BGRA 动画通过真实窗口验收，absolute-deadline 30 fps 调度实测约 29.3 fps，统一日志
确认宿主启动和 Metal 路径切换。验证宿主现已提升为 session-driven viewer，并保留
Offline Validation：Remote Session 提供 TCP、系统信任 TLS、显式测试用不安全 TLS、
非持久化 ticket 密码及连接/错误状态；单一监督任务消费 frame/cursor/mouse-mode/
failure/disconnect，键鼠输入经 256 项有界 FIFO 由单一 sender 顺序发送，不为每条输入
创建 Task。真实窗口已验证模式切换、表单、连接取消和本地错误反馈；完整本地门槛为
194 tests / 45 suites。由于没有 SPICE listener，成功握手、真实画面/游标和 guest 输入
回环仍标记为外部待验证。下一本地项是 reconnect/backoff、非秘密 endpoint profile
和 viewer telemetry；这三项现已完成：每次连接有 10 秒 deadline，可选自动重连最多
五次并采用 1/2/4/8/16 秒退避，Disconnect/模式切换可立即取消连接或等待；profile
只编码名称、host、port、TLS，密码不进入持久化或日志；统一日志按 Profiles、
Navigation、Session 分类，真实日志已验证 attempt/timeout/retry/cancel。为保证 deadline
真正生效，`NetworkSpiceTransport` 的建立过程也改为可取消的 state stream 等待，并有
focused cancellation test。Playback viewer 接入现已完成：仅在 bootstrap 发现
Playback channel 0 后创建并监督 `SpiceAudioPlaybackSink`，连接状态栏显示格式、静音、
重同步、丢包与 underrun 计数；disconnect/retry/模式切换会先停止 sink，断开态真实日志
确认不会提前初始化 AVAudioEngine。Record viewer 接入也已完成：发现 Record channel 0
只显示 `Mic Off`，仅用户点击 Enable Mic 后才查询/请求系统权限并创建 capture source；
授权等待可取消，独立 request generation 会丢弃 disconnect/retry/模式切换后的迟到授权
结果。状态栏显示授权、server start/stop、格式、静音、失败及有界 overflow/drop 计数；
真实 bundle 已含 `NSMicrophoneUsageDescription`，启动日志确认未提前请求权限或附加 source。
完整本地门槛现为 201 tests / 48 suites。Agent clipboard viewer bridge 也已完成：每个
session 默认关闭，关闭时只排空有界 `agentEvents` 而不访问 `NSPasteboard`，用户点击
Enable Clipboard 后才把单一事件流交给 `SpiceAgentManager`；enable/disable 会等待旧消费
者结束后再交接。状态栏只显示协商、host/guest ownership 字节数、oversized reject 和失败，
不保留或记录正文，并明确区分 clipboard UTF-8、Inputs 扫描码与 guest IME composition。
真实 app 启动日志确认没有 Clipboard attachment，完整门槛现为 203 tests / 49 suites。
共享 Agent supervisor 和 host-to-guest file transfer viewer 也已完成：manager 始终消费
Agent/control/file-transfer，pasteboard policy 可动态切换；关闭时 capability 不含 clipboard/
by-demand、忽略迟到 guest clipboard 命令且公开同步入口不会进入 AppKit bridge。文件菜单
通过单一 `NSOpenPanel` 显式选择 regular file，显示最多八条 queued/approval/progress/
complete/failure/cancel 状态并支持逐项取消；文件传输不会改变 clipboard policy，日志不记
文件名或路径。完整门槛现为 206 tests / 50 suites。下一项是在同一 Agent manager 上接入
viewer monitor inventory 与 resolution request，同时保持 Display Channel 通知为权威几何；
该项也已完成：状态栏 monitor popover 按 Display Channel ID 展示 monitor/surface/位置/尺寸，
支持正数宽高校验后的单屏 resolution request，并分别显示 queued/sent/acknowledged/
rejected/unsupported/failed/applied。Agent ACK 不修改 inventory，只有后续匹配的 Display
Channel 通知才确认 applied；空通知不会擦除最后一份有效 inventory。完整门槛现为
209 tests / 51 suites，真实 app 已完成构建启动验证。下一本地项是 capability-aware 的
多屏 layout editor，包括 sparse monitor ID 与 signed position；该项也已完成。编辑器支持
增删 row、0...255 ID、UInt32 正尺寸与 signed Int32 坐标，通过独立 Agent support stream
在提交前门控 explicit sparse/position capability，协议层仍二次校验。单 Display Channel
保留 ID；多 channel 因 ID 属于各自 channel-local namespace，会顺序重映射 request ID 并
明确提示，避免宣称可无损往返。多屏 applied 仍只由匹配的权威 Display inventory 确认。
完整门槛现为 214 tests / 52 suites。下一本地 Stage F 项是 migration control-plane 解码与
cancellation-safe supervised handoff 状态机；该项也已完成。Main Channel 现在严格解码
BEGIN/BEGIN_SEAMLESS/CANCEL/SWITCH_HOST/END 及 destination seamless ACK/NACK，目标
host/cert-subject 是 4096-byte bounded、严格 NUL terminated、无 embedded NUL 的 UTF-8。
generation-tagged coordinator 会取消被替代的 preparation、忽略迟到 completion，并只在
READY 后接受 END commit；handoff task 会随替换、disconnect/receive failure 一起取消，
migration capability 仍不广告。prepared target-session 与 atomic channel-set adoption 也已
完成：Main/全部子 Channel 先在局部容器完成认证和 bootstrap，不会提前写入活动 session；
失败或 CANCEL 只关闭 target。source 收到 END 后，先向 target 写 MIGRATE_END，再一次性
替换 Main/子 Channel set、启动 target supervision，最后关闭 source。双 session fixture
验证后续 Main event 与 Inputs 写入都落到 target，另有失败回滚与阻塞准备取消覆盖；TLS
source 禁止降级到 plaintext port，尚不能验证的 certificate subject 会明确拒绝。
destination-side seamless negotiation 与 TLS endpoint-policy fixture matrix 也已完成，并修正
了上一轮 fixture 暴露的 wire contract：migration target 不等待第二份 MAIN_INIT/
CHANNELS_LIST，而是复用 source session ID 与 source Channel inventory。target-only Main Link
按请求广告 migration bits；server 支持时精确发送 DST_DO_SEAMLESS(source version)，严格只接收
ACK/NACK，再向 source 回 CONNECTED_SEAMLESS 或 CONNECTED。common-Channel migration
flush/state transfer 现也已完成：
ChannelConnection 严格解析仅含 NEED_FLUSH/NEED_DATA_TRANSFER 的 MIGRATE，一旦进入迁移即
封住后续普通 client write，先发送 FLUSH_MARK，再按需读取且只接受紧随其后的 opaque
MIGRATE_DATA。Session 等待 Main 与所有 source 子 Channel 全部到界后，才把每份 state 转发
给匹配的 target connection 并原子接管；partial flush 后的 CANCEL 会只恢复已暂停的 source
connection。state-preserving connection rebinding 也已完成：prepared target 只提供已认证的
新 connection，现有 Main/Display/Cursor/Inputs/Playback/Record/Passive actor 在统一 inventory
校验后原位换绑；源 connection 随后关闭，actor 内的 surface/image cache、cursor cache、Inputs
按钮状态、Agent token/decoder、音频流状态及共享 multimedia clock 均保留。聚焦测试逐项验证
这些状态，`SWITCH_HOST` 仍保留完整替换 Session 的语义。普通 Main Link 现在广告 semi-seamless
与 seamless migration capability。其后的 Smartcard、USB redirection 与 WebDAV 本地闭环也已
完成。Smartcard 严格实现 VSCARD 0.0.2 消息、边界和串行控制队列，Session 只接受应用显式添加
的 reader/card/APDU，不枚举宿主卡。USB redirection 通过 SpiceVMC Channel 接入
`libusbredirhost` exact backend，设备必须由应用以 bus/address 显式选择，backend 执行 guest
filter 且不公开自动枚举。WebDAV 严格实现 Port 初始化/事件及多 client mux；原生 class-1
WebDAV backend 默认只读，仅在应用显式提供 root 与 read-write policy 后允许 PUT/MKCOL/
DELETE/COPY/MOVE，并拒绝路径与符号链接逃逸。Session 也保留 raw packet/event bridge，便于
嵌入方替换 backend。当前 warnings-as-errors 本地门槛为 270 tests / 63 suites，协议生成一致性、
SwiftPM build 和 app bundle verify 均纳入验收。

至此阶段 F 的 listener-independent 实现已本地收口；真实 Smartcard、USB device、guest
WebDAV client、音频、文件传输、多屏/migration 回环，以及 H.264/H.265 capability 广告仍分别
等待 listener/device 环境联调，不能记为外部互操作已验证。

---

## 25. 关键架构决策

### 应采用

* 一个 Session actor
* 一个 Channel 一个 actor
* Channel 内顺序处理
* TaskGroup 管理 Channel 生命周期
* AsyncStream 输出事件
* typed throws
* 显式 capability 类型
* 显式小端解析
* Span 用于同步热路径
* `~Copyable` 用于唯一资源
* `sending` 用于所有权转移
* SurfaceStore 与协议 Channel 分离
* unsafe interop 单独模块
* 先 CPU framebuffer，再 IOSurface/Metal

### 不应采用

* 一个巨大的 `SpiceClient` actor
* 每个消息创建 Task
* 所有状态都放到 MainActor
* 直接导入 packed C struct 作为 wire model
* 用 `Data` slice 随意长期持有大包
* 使用 callback + 锁模拟 GLib signal
* 把所有事件放入一个无界 AsyncStream
* 无差别并行解码 Display 消息
* 广泛使用 `@unchecked Sendable`
* 首版同时重写协议、全部 codec、音频和 USB

---

## 26. 推荐的最终公开 API

```swift
public struct SessionOptions: Sendable {
    public var protocolLimits: ProtocolLimits
    public var tlsPolicy: TLSTrustPolicy
    public var preferredCodecs: [SpiceCodec]
    public var enableAudio: Bool
    public var enableClipboard: Bool
}

public actor SpiceSession {
    public nonisolated let controlEvents:
        AsyncStream<ControlEvent>

    public nonisolated let frames:
        AsyncStream<FrameSnapshot>

    public init(options: SessionOptions)

    public func run(
        endpoint: SpiceEndpoint,
        credentials: consuming SpiceCredentials?
    ) async throws(SpiceError)

    public func send(
        _ event: InputEvent
    ) async throws(SpiceError)

    public func requestResolution(
        _ resolution: DisplayResolution
    ) async throws(SpiceError)

    public func requestDisconnect() async
}
```

应用代码：

```swift
@MainActor
final class ConsoleViewModel {
    private let session: SpiceSession
    private var sessionTask: Task<Void, Never>?

    func connect(
        endpoint: SpiceEndpoint,
        credentials: consuming SpiceCredentials?
    ) {
        sessionTask = Task {
            do {
                try await session.run(
                    endpoint: endpoint,
                    credentials: credentials
                )
            } catch {
                handle(error)
            }
        }

        Task {
            for await frame in session.frames {
                present(frame)
            }
        }
    }

    func disconnect() {
        sessionTask?.cancel()
        sessionTask = nil
    }
}
```

---

## 27. 总结

Swift 版不应只是 Rust `spice-client` 的语法翻译，而应保留它正确的模块边界：

```text
Transport
→ ChannelConnection
→ Main/Display/Inputs/Cursor
→ Client facade
```

同时使用 Swift 6 重新设计运行模型：

```text
Tokio tasks
    → structured TaskGroup

Arc/Mutex
    → actor isolation

Vec<u8> parsing
    → Data + Span

Result<T, E>
    → typed throws

move semantics
    → consuming / borrowing / sending

RAII wrapper
    → ~Copyable + deinit

callback
    → bounded AsyncStream

shared framebuffer
    → SurfaceStore actor + write lease
```

最终目标应是：

> 协议顺序由 actor 保证，任务生命周期由结构化并发保证，跨隔离域的数据由 Sendable/sending 保证，唯一资源由非复制类型保证，二进制内存安全由 Span 和显式边界检查保证。
