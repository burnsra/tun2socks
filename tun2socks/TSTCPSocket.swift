import Foundation
import lwip

/**
 The delegate that developer should implement to handle various TCP events.
 */
public protocol TSTCPSocketDelegate: class {
    /**
     The socket is closed on tx side (FIN received). We will not read any data.
     */
    func localDidClose(_ socket: TSTCPSocket)

    /**
     The socket is reseted (RST received), it should be released immediately.
     */
    func socketDidReset(_ socket: TSTCPSocket)

    /**
     The socket is aborted (RST sent), it should be released immediately.
     */
    func socketDidAbort(_ socket: TSTCPSocket)

    /**
     The socket is closed. This will only be triggered if the socket is closed actively by calling `close()`. It should be released immediately.
     */
    func socketDidClose(_ socket: TSTCPSocket)


    /**
     Socket read data from local tx side.

     - parameter data: The read data.
     - parameter from: The socket object.
     */
    func didReadData(_ data: Data, from: TSTCPSocket)

    /**
     The socket has sent the specific length of data.

     - parameter length: The length of data being ACKed.
     - parameter from:   The socket.
     */
    func didWriteData(_ length: Int, from: TSTCPSocket)
}

// There is no way the error will be anything but ERR_OK, so the `error` parameter should be ignored.
func tcp_recv_func(_ arg: UnsafeMutableRawPointer?, pcb: UnsafeMutablePointer<tcp_pcb>, buf: UnsafeMutablePointer<pbuf>, error: err_t) -> err_t {
    assert(error == err_t(ERR_OK))

    assert(arg != nil)

    guard let socket = SocketDict.lookup(UnsafeMutablePointer<Int>(arg).pointee) else {
        // we do not know what this socket is, abort it
        tcp_abort(pcb)
        return err_t(ERR_ABRT)
    }
    socket.recved(buf)
    return err_t(ERR_OK)
}

func tcp_sent_func(_ arg: UnsafeMutableRawPointer?, pcb: UnsafeMutablePointer<tcp_pcb>, len: UInt16) -> err_t {
    assert(arg != nil)

    guard let socket = SocketDict.lookup(UnsafeMutablePointer<Int>(arg).pointee) else {
        // we do not know what this socket is, abort it
        tcp_abort(pcb)
        return err_t(ERR_ABRT)
    }
    socket.sent(Int(len))
    return err_t(ERR_OK)
}

func tcp_err_func(_ arg: UnsafeMutableRawPointer?, error: err_t) {
    assert(arg != nil)

    SocketDict.lookup(UnsafeMutablePointer<Int>(arg).pointee)?.errored(error)
}

struct SocketDict {
    static var socketDict: [Int:TSTCPSocket] = [:]

    static func lookup(_ id: Int) -> TSTCPSocket? {
        return socketDict[id]
    }

    static func newKey() -> Int {
        var key = arc4random()
        while let _ = socketDict[Int(key)] {
            key = arc4random()
        }

        return Int(key)
    }
}

/**
 The TCP socket class.

 - note: Unless one of `socketDidReset(_:)`, `socketDidAbort(_:)` or `socketDidClose(_:)` delegation methods is called, please do `close()`the socket actively and wait for `socketDidClose(_:)` before releasing it.
 - note: This class is thread-safe.
 */
public final class TSTCPSocket {
    fileprivate var pcb: UnsafeMutablePointer<tcp_pcb>?
    /// The source IPv4 address.
    public let sourceAddress: in_addr
    /// The destination IPv4 address
    public let destinationAddress: in_addr
    /// The source port.
    public let sourcePort: UInt16
    /// The destination port.
    public let destinationPort: UInt16

    fileprivate let queue: DispatchQueue
    fileprivate var identity: Int
    fileprivate let identityArg: UnsafeMutablePointer<Int>
    fileprivate var closedSignalSend = false


    var isValid: Bool {
        return pcb != nil
    }

    /// Whether the socket is connected (we can receive and send data).
    public var isConnected: Bool {
        return isValid && pcb!.pointee.state.rawValue >= ESTABLISHED.rawValue && pcb!.pointee.state.rawValue < CLOSED.rawValue
    }

    /**
     The delegate that handles various TCP events.

     - warning: This should be set immediately when developer gets an instance of TSTCPSocket from `didAcceptTCPSocket(_:)` on the same thread that calls it. Simply say, just set it when you get an instance of TSTCPSocket.
     */
    public weak var delegate: TSTCPSocketDelegate?

    init(pcb: UnsafeMutablePointer<tcp_pcb>, queue: DispatchQueue) {
        self.pcb = pcb
        self.queue = queue

        // see comments in "lwip/src/core/ipv4/ip.c"
        sourcePort = pcb.pointee.remote_port
        destinationPort = pcb.pointee.local_port
        sourceAddress = in_addr(s_addr: pcb.pointee.remote_ip.addr)
        destinationAddress = in_addr(s_addr: pcb.pointee.local_ip.addr)

        identity = SocketDict.newKey()
        identityArg = UnsafeMutablePointer<Int>(allocatingCapacity: 1)
        identityArg.pointee = identity
        SocketDict.socketDict[identity] = self

        tcp_arg(pcb, identityArg)
        tcp_recv(pcb, tcp_recv_func)
        tcp_sent(pcb, tcp_sent_func)
        tcp_err(pcb, tcp_err_func)
    }

    func errored(_ error: err_t) {
        release()
        switch Int32(error) {
        case ERR_RST:
            delegate?.socketDidReset(self)
        case ERR_ABRT:
            delegate?.socketDidAbort(self)
        default:
            break
        }
    }

    func sent(_ length: Int) {
        delegate?.didWriteData(length, from: self)
    }

    func recved(_ buf: UnsafeMutablePointer<pbuf>?) {
        if buf == nil {
            delegate?.localDidClose(self)
        } else {
            let data = NSMutableData(length: Int((buf?.pointee.tot_len)!))!
            pbuf_copy_partial(buf, data.mutableBytes, (buf?.pointee.tot_len)!, 0)
            delegate?.didReadData(data as Data, from: self)
            if isValid {
                tcp_recved(pcb, (buf?.pointee.tot_len)!)
            }
            pbuf_free(buf)
        }
    }

    /**
     Send data to local rx side.

     - parameter data: The data to send.
     */
    public func writeData(_ data: Data) {
        queue.async {
            guard self.isValid else {
                return
            }

            let err = tcp_write(self.pcb, (data as NSData).bytes, UInt16(data.count), UInt8(TCP_WRITE_FLAG_COPY))
            if  err != err_t(ERR_OK) {
                self.close()
            } else {
                tcp_output(self.pcb)
            }

        }
    }

    /**
     Close the socket. The socket should not be read or write again.
     */
    public func close() {
        queue.async {
            guard self.isValid else {
                return
            }

            tcp_arg(self.pcb, nil)
            tcp_recv(self.pcb, nil)
            tcp_sent(self.pcb, nil)
            tcp_err(self.pcb, nil)

            assert(tcp_close(self.pcb)==err_t(ERR_OK))

            self.release()
            // the lwip will handle the following things for us
            self.delegate?.socketDidClose(self)
        }
    }

    /**
     Reset the socket. The socket should not be read or write again.
     */
    public func reset() {
        queue.async {
            guard self.isValid else {
                return
            }

            tcp_arg(self.pcb, nil)
            tcp_recv(self.pcb, nil)
            tcp_sent(self.pcb, nil)
            tcp_err(self.pcb, nil)

            tcp_abort(self.pcb)
            self.release()

            self.delegate?.socketDidClose(self)
        }
    }

    func release() {
        pcb = nil
        identityArg.deinitialize()
        identityArg.deallocate(capacity: 1)
        SocketDict.socketDict.removeValue(forKey: identity)
    }

    deinit {
    }
}
