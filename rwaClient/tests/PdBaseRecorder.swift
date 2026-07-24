//
//  PdBaseRecorder.swift
//  rwaclientTests
//
//  Swift analogue of rwa-creator's tools/trace/fake_libpd: records every
//  message the engine sends towards Pure Data WITHOUT letting it reach libpd.
//
//  While active, the four PdBase send class methods used by RwaGameLoop —
//  sendFloat:toReceiver:, sendDouble:toReceiver: (PdBase_Extension),
//  sendBangToReceiver: and sendSymbol:toReceiver: — are replaced with
//  record-only implementations. Because no message reaches Pd, no patch ever
//  starts playing and no real "-playfinished" bang can fire; scenarios inject
//  those deterministically by calling rwagameloop.receiveBang(fromSource:),
//  mirroring fake_libpd_inject_bang on the C++ side.
//
//  Everything else (PdBase.openFile / dollarZeroForFile / closeFile and the
//  PdDispatcher) stays real, so patcher tags are genuine Pd $0 values.
//

import Foundation
import ObjectiveC

final class PdBaseRecorder {

    enum Kind {
        case float   // recorded value went through libpd_float in production
        case bang
        case symbol
    }

    struct Message {
        let kind: Kind
        let receiver: String
        let value: Double    // valid for .float
        let symbol: String?  // valid for .symbol
    }

    static let shared = PdBaseRecorder()

    /// Called synchronously for every intercepted send while active.
    var handler: ((Message) -> Void)?

    private(set) var isActive = false
    private var originalImps: [(method: Method, imp: IMP)] = []

    private init() {}

    func start(handler: @escaping (Message) -> Void) {
        precondition(!isActive, "PdBaseRecorder is already active")
        self.handler = handler
        swizzleAll()
        isActive = true
    }

    func stop() {
        guard isActive else { return }
        for (method, imp) in originalImps.reversed() {
            method_setImplementation(method, imp)
        }
        originalImps.removeAll()
        handler = nil
        isActive = false
    }

    private func record(_ message: Message) {
        handler?(message)
    }

    private func swizzleAll() {
        // + (int)sendFloat:(float)value toReceiver:(NSString *)receiverName
        replaceClassMethod("sendFloat:toReceiver:", with: {
            let block: @convention(block) (AnyObject, Float, NSString) -> Int32 = { _, value, receiver in
                PdBaseRecorder.shared.record(Message(kind: .float, receiver: receiver as String,
                                                     value: Double(value), symbol: nil))
                return 0
            }
            return imp_implementationWithBlock(block)
        }())

        // + (int)sendDouble:(double)value toReceiver:(NSString *)receiverName
        // (PdBase_Extension; production forwards to libpd_float, i.e. the value
        // is truncated to float — record the same truncation so traces match
        // the C++ fake, whose recorder only ever sees floats.)
        replaceClassMethod("sendDouble:toReceiver:", with: {
            let block: @convention(block) (AnyObject, Double, NSString) -> Int32 = { _, value, receiver in
                PdBaseRecorder.shared.record(Message(kind: .float, receiver: receiver as String,
                                                     value: Double(Float(value)), symbol: nil))
                return 0
            }
            return imp_implementationWithBlock(block)
        }())

        // + (int)sendBangToReceiver:(NSString *)receiverName
        replaceClassMethod("sendBangToReceiver:", with: {
            let block: @convention(block) (AnyObject, NSString) -> Int32 = { _, receiver in
                PdBaseRecorder.shared.record(Message(kind: .bang, receiver: receiver as String,
                                                     value: 0, symbol: nil))
                return 0
            }
            return imp_implementationWithBlock(block)
        }())

        // + (int)sendSymbol:(NSString *)symbol toReceiver:(NSString *)receiverName
        replaceClassMethod("sendSymbol:toReceiver:", with: {
            let block: @convention(block) (AnyObject, NSString, NSString) -> Int32 = { _, symbol, receiver in
                PdBaseRecorder.shared.record(Message(kind: .symbol, receiver: receiver as String,
                                                     value: 0, symbol: symbol as String))
                return 0
            }
            return imp_implementationWithBlock(block)
        }())
    }

    private func replaceClassMethod(_ selectorName: String, with imp: IMP) {
        let selector = NSSelectorFromString(selectorName)
        guard let method = class_getClassMethod(PdBase.self, selector) else {
            fatalError("PdBase does not respond to +\(selectorName) — libpd API drifted?")
        }
        let original = method_setImplementation(method, imp)
        originalImps.append((method, original))
    }
}
