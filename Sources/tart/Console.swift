import Foundation
import NIOCore
import NIOPosix
import Virtualization
import Darwin.POSIX

final class GlueHandler: ChannelDuplexHandler {
  typealias InboundIn = NIOAny
  typealias OutboundIn = NIOAny
  typealias OutboundOut = NIOAny

  private var partner: GlueHandler?
  private var context: ChannelHandlerContext?
  private var pendingRead: Bool = false

  private init() {
  }

  static func matchedPair() -> (GlueHandler, GlueHandler) {
    let first = GlueHandler()
    let second = GlueHandler()

    first.partner = second
    second.partner = first

    return (first, second)
  }

  private func partnerWrite(_ data: NIOAny) {
    context?.write(data, promise: nil)
  }

  private func partnerFlush() {
    context?.flush()
  }

  private func partnerWriteEOF() {
    context?.close(mode: .output, promise: nil)
  }

  private func partnerCloseFull() {
    context?.close(promise: nil)
  }

  private func partnerBecameWritable() {
    if pendingRead {
      pendingRead = false
      context?.read()
    }
  }

  private var partnerWritable: Bool {
    context?.channel.isWritable ?? false
  }

  func handlerAdded(context: ChannelHandlerContext) {
    self.context = context
  }

  func handlerRemoved(context _: ChannelHandlerContext) {
    context = nil
    partner = nil
  }

  func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
    partner?.partnerWrite(data)
  }

  func channelReadComplete(context _: ChannelHandlerContext) {
    partner?.partnerFlush()
  }

  func channelInactive(context _: ChannelHandlerContext) {
    partner?.partnerCloseFull()
  }

  func userInboundEventTriggered(context _: ChannelHandlerContext, event: Any) {
    if let event = event as? ChannelEvent, case .inputClosed = event {
      // We have read EOF.
      partner?.partnerWriteEOF()
    }
  }

  func errorCaught(context _: ChannelHandlerContext, error : Error) {
    defaultLogger.appendNewLine("Error in pipeline: \(error)")
    partner?.partnerCloseFull()
  }

  func channelWritabilityChanged(context: ChannelHandlerContext) {
    if context.channel.isWritable {
      partner?.partnerBecameWritable()
    }
  }

  func read(context: ChannelHandlerContext) {
    if let partner = partner, partner.partnerWritable {
      context.read()
    } else {
      pendingRead = true
    }
  }
}

class Console {
  let mainGroup: EventLoopGroup
  let socketPipe: Pipe
  let bootstrap: ServerBootstrap
  let consoleSocket: String
  var channel: Channel?

  deinit {
    try? mainGroup.syncShutdownGracefully()
  }

  init(diskURL: URL) {
    let consoleSocket = URL(fileURLWithPath: "tart-agent.sock", isDirectory: false, relativeTo: diskURL).absoluteURL.path()
    let mainGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    let socketPipe = Pipe()
    let bootstrap = ServerBootstrap(group: mainGroup)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { inboundChannel in
        // Dup fd pipe because nio close it then the socket is closed
        let input = dup(socketPipe.fileHandleForReading.fileDescriptor)
        let output = dup(socketPipe.fileHandleForWriting.fileDescriptor)

        return NIOPipeBootstrap(group: inboundChannel.eventLoop)
          .takingOwnershipOfDescriptors(input: input, output: output)
          .flatMap { childChannel in
            let (ours, theirs) = GlueHandler.matchedPair()

            return childChannel.pipeline.addHandlers([ours])
              .flatMap {
                inboundChannel.pipeline.addHandlers([theirs])
              }
          }
      }

    unlink(consoleSocket)

    self.consoleSocket = consoleSocket
    self.mainGroup = mainGroup
    self.socketPipe = socketPipe
    self.bootstrap = bootstrap
  }

  private func setChannel(_ channel: any NIOCore.Channel) {
    self.channel = channel
  }

  private func create(configuration: VZVirtualMachineConfiguration) -> Console {
    let consolePort: VZVirtioConsolePortConfiguration = VZVirtioConsolePortConfiguration()
    let consoleDevice: VZVirtioConsoleDeviceConfiguration = VZVirtioConsoleDeviceConfiguration()

    consolePort.name = "tart-agent"
    consolePort.attachment = VZFileHandleSerialPortAttachment(
      fileHandleForReading: self.socketPipe.fileHandleForReading,
      fileHandleForWriting: self.socketPipe.fileHandleForWriting)
    consoleDevice.ports[0] = consolePort

    configuration.consoleDevices.append(consoleDevice)

    let binder = self.bootstrap.bind(unixDomainSocketPath: consoleSocket)
    
    binder.whenComplete{ result in
      switch result {
      case let .success(channel):
        self.setChannel(channel)
        defaultLogger.appendNewLine("Console listening on unix:\(self.consoleSocket)")
      case let .failure(error):
        defaultLogger.appendNewLine("Failed to bind console on unix:\(self.consoleSocket), \(error)")
      }
    }

    return self
  }

  func close() {
    if let channel {
      let closeFuture = channel.close()

      closeFuture.whenComplete { result in
        switch result {
        case .success:
          defaultLogger.appendNewLine("Console closed unix:\(self.consoleSocket)")
        case let .failure(error):
          defaultLogger.appendNewLine("Failed to close console unix:\(self.consoleSocket), \(error)")
        }
      }

      try? closeFuture.wait()
    }
  }

  static func setupConsole(diskURL: URL, configuration: VZVirtualMachineConfiguration) -> Console {
    Console(diskURL: diskURL).create(configuration: configuration)
  }
}
