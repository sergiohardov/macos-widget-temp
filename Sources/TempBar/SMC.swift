import Foundation
import IOKit

// MARK: - Низкоуровневый доступ к AppleSMC через IOKit.
// Только чтение ключей. Никаких записей в SMC, ничего в системе не меняется.

// 32-байтовый буфер данных SMC.
typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}

// Операции, которые драйвер выполняет (кладутся в data8).
private let kSMCReadKey: UInt8 = 5
private let kSMCGetKeyFromIndex: UInt8 = 8
private let kSMCGetKeyInfo: UInt8 = 9
// Селектор IOConnectCallStructMethod.
private let kSMCHandleYPCEvent: UInt32 = 2

private func fourCharCode(_ str: String) -> UInt32 {
    var result: UInt32 = 0
    for ch in str.utf8.prefix(4) {
        result = (result << 8) + UInt32(ch)
    }
    return result
}

private func stringFromFourCharCode(_ code: UInt32) -> String {
    let chars = [
        UInt8((code >> 24) & 0xff),
        UInt8((code >> 16) & 0xff),
        UInt8((code >> 8) & 0xff),
        UInt8(code & 0xff)
    ]
    return String(decoding: chars, as: UTF8.self)
}

final class SMC {
    static let shared = SMC()

    private var connection: io_connect_t = 0
    private(set) var isOpen = false

    private init() {
        open()
    }

    deinit {
        close()
    }

    private func open() {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != 0 else { return }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)
        isOpen = (result == kIOReturnSuccess)
    }

    private func close() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
        isOpen = false
    }

    private func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        var output = SMCParamStruct()
        let inputSize = MemoryLayout<SMCParamStruct>.stride
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(
            connection,
            kSMCHandleYPCEvent,
            &input,
            inputSize,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess else { return nil }
        return output
    }

    // Читает сырое значение ключа: тип данных + байты.
    private func read(key: UInt32) -> (type: UInt32, size: UInt32, bytes: SMCBytes)? {
        guard isOpen else { return nil }

        var info = SMCParamStruct()
        info.key = key
        info.data8 = kSMCGetKeyInfo
        guard let infoOut = call(&info) else { return nil }

        var read = SMCParamStruct()
        read.key = key
        read.keyInfo.dataSize = infoOut.keyInfo.dataSize
        read.keyInfo.dataType = infoOut.keyInfo.dataType
        read.data8 = kSMCReadKey
        guard let readOut = call(&read) else { return nil }

        return (infoOut.keyInfo.dataType, infoOut.keyInfo.dataSize, readOut.bytes)
    }

    // Декодирует значение температуры из ключа (°C) либо nil.
    func temperature(key: String) -> Double? {
        guard let raw = read(key: fourCharCode(key)) else { return nil }
        return Self.decodeTemperature(type: raw.type, bytes: raw.bytes)
    }

    static func decodeTemperature(type: UInt32, bytes: SMCBytes) -> Double? {
        let typeStr = stringFromFourCharCode(type)
        switch typeStr {
        case "flt ":
            // 32-битный little-endian float (Apple Silicon).
            let value = Float(bitPattern:
                UInt32(bytes.0) |
                (UInt32(bytes.1) << 8) |
                (UInt32(bytes.2) << 16) |
                (UInt32(bytes.3) << 24)
            )
            return value.isFinite ? Double(value) : nil
        case "sp78":
            // 16-битный signed fixed point (Intel).
            let raw = Int16(bitPattern: UInt16(bytes.0) << 8 | UInt16(bytes.1))
            return Double(raw) / 256.0
        case "ioft":
            // 64-битный fixed point (целая часть в старших байтах).
            var value: UInt64 = 0
            value |= UInt64(bytes.0) << 56
            value |= UInt64(bytes.1) << 48
            value |= UInt64(bytes.2) << 40
            value |= UInt64(bytes.3) << 32
            value |= UInt64(bytes.4) << 24
            value |= UInt64(bytes.5) << 16
            value |= UInt64(bytes.6) << 8
            value |= UInt64(bytes.7)
            return Double(value) / 65536.0
        default:
            return nil
        }
    }

    // Перечисляет все ключи SMC (нужно для авто-обнаружения сенсоров).
    func allKeys() -> [String] {
        guard isOpen else { return [] }
        guard let raw = read(key: fourCharCode("#KEY")) else { return [] }
        let count = UInt32(raw.bytes.0) << 24 | UInt32(raw.bytes.1) << 16 |
                    UInt32(raw.bytes.2) << 8 | UInt32(raw.bytes.3)
        guard count > 0, count < 10000 else { return [] }

        var keys: [String] = []
        for index in 0..<count {
            var input = SMCParamStruct()
            input.data8 = kSMCGetKeyFromIndex
            input.data32 = index
            guard let out = call(&input) else { continue }
            keys.append(stringFromFourCharCode(out.key))
        }
        return keys
    }
}
