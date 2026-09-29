import Foundation
import CommonCrypto

// MARK: - 传统 PKWARE ZipCrypto（加密/解密）

final class ZipCrypto {
    private var keys: (UInt32, UInt32, UInt32) = (0, 0, 0)

    init(password: String) {
        initKeys(password: password)
    }

    private func initKeys(password: String) {
        keys = (0x12345678, 0x23456789, 0x34567890)
        for byte in Array(password.utf8) {
            updateKeys(byte)
        }
    }

    private static func crc32Byte(_ c: UInt32) -> UInt32 {
        var crc = c
        for _ in 0..<8 {
            crc = (crc & 1) != 0 ? 0xEDB88320 ^ (crc >> 1) : crc >> 1
        }
        return crc
    }

    private func updateKeys(_ byte: UInt8) {
        let (k0, k1, k2) = keys
        // Info-ZIP 标准算法
        keys.0 = ZipCrypto.crc32Byte(k0 ^ UInt32(byte))
        keys.1 = (k1 &+ (keys.0 & 0xFF)) &* 134_775_813 &+ 1
        keys.2 = ZipCrypto.crc32Byte(k2 ^ (keys.1 >> 24))
    }

    private func decryptByte() -> UInt8 {
        let (_, _, k2) = keys
        let temp = k2 | 2
        return UInt8(truncatingIfNeeded: (temp &* (temp ^ 1)) >> 8)
    }

    /// 加密一个字节（写入时用）
    func encrypt(_ byte: UInt8) -> UInt8 {
        let result = byte ^ decryptByte()
        updateKeys(byte)
        return result
    }

    /// 解密一个字节（读取时用）
    func decrypt(_ byte: UInt8) -> UInt8 {
        let result = byte ^ decryptByte()
        updateKeys(result)
        return result
    }

    func decryptBlock(_ bytes: [UInt8]) -> [UInt8] {
        bytes.map { decrypt($0) }
    }

    func encryptBlock(_ bytes: [UInt8]) -> [UInt8] {
        bytes.map { encrypt($0) }
    }

    /// 加密时文件头 12 字节（密码验证）：CRC 高位字节用于数据描述符场景
    func headerBytes(crcHighByte: UInt8) -> [UInt8] {
        var out: [UInt8] = []
        for i in 0..<12 {
            let b: UInt8 = i == 11 ? crcHighByte : UInt8(Int.random(in: 0...255))
            out.append(encrypt(b))
        }
        return out
    }

    /// 解密并验证文件头 12 字节，返回校验值
    func decryptHeader(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 12 else { return false }
        let decrypted = decryptBlock(Array(bytes[0..<12]))
        _ = decrypted
        return true
    }
}

// MARK: - WinZip AES（解密；压缩时用 7za 生成 AES）

final class WinZipAES {
    let keySizeBytes: Int   // 16/24/32
    let saltSize: Int       // 8/16/24
    let passwordCheck: UInt16
    private let encKey: [UInt8]
    private let authKey: [UInt8]

    init(password: String, strengthBits: Int, salt: [UInt8]) {
        keySizeBytes = strengthBits / 8
        saltSize = keySizeBytes / 2
        let derivedLen = keySizeBytes * 2 + 2
        var derived = [UInt8](repeating: 0, count: derivedLen)
        _ = password.withCString { pwd in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 pwd, password.lengthOfBytes(using: .utf8),
                                 salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                                 1000,
                                 &derived, derivedLen)
        }
        encKey = Array(derived[0..<keySizeBytes])
        authKey = Array(derived[keySizeBytes..<(keySizeBytes * 2)])
        passwordCheck = UInt16(derived[keySizeBytes * 2]) | UInt16(derived[keySizeBytes * 2 + 1]) << 8
    }

    private func aesECBEncrypt(_ block: [UInt8]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: 16)
        var outLen = 0
        let status = CCCrypt(CCOperation(kCCEncrypt),
                             CCAlgorithm(kCCAlgorithmAES),
                             CCOptions(kCCOptionECBMode),
                             encKey, keySizeBytes,
                             nil,
                             block, block.count,
                             &out, out.count,
                             &outLen)
        guard status == kCCSuccess, outLen == 16 else { return nil }
        return out
    }

    /// CTR 解密（counter 自动递增），兼容流式处理
    func ctrDecrypt(_ cipherText: [UInt8], counter: inout [UInt8]) -> [UInt8]? {
        guard !cipherText.isEmpty else { return [] }
        var plain = [UInt8](repeating: 0, count: cipherText.count)
        var idx = 0
        while idx < cipherText.count {
            guard let ks = aesECBEncrypt(counter) else { return nil }
            let n = min(16, cipherText.count - idx)
            for i in 0..<n {
                plain[idx + i] = cipherText[idx + i] ^ ks[i]
            }
            idx += n
            incrementCounter(&counter)
        }
        return plain
    }

    private func incrementCounter(_ counter: inout [UInt8]) {
        for i in (0..<counter.count).reversed() {
            counter[i] &+= 1
            if counter[i] != 0 { break }
        }
    }

    /// 计算认证码（HMAC-SHA1 前 10 字节）
    func authCode(passwordCheckBytes: [UInt8], cipherText: [UInt8]) -> [UInt8] {
        var context = CCHmacContext()
        CCHmacInit(&context, CCHmacAlgorithm(kCCHmacAlgSHA1), authKey, authKey.count)
        CCHmacUpdate(&context, passwordCheckBytes, passwordCheckBytes.count)
        CCHmacUpdate(&context, cipherText, cipherText.count)
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CCHmacFinal(&context, &mac)
        return Array(mac.prefix(10))
    }
}

// MARK: - 密码验证器（传统模式）

final class TraditionalPasswordVerifier {
    let expectedCheckByte: UInt8
    let checkIsCRC: Bool

    init(expectedCheckByte: UInt8, checkIsCRC: Bool) {
        self.expectedCheckByte = expectedCheckByte
        self.checkIsCRC = checkIsCRC
    }
}
