import Foundation

enum AgentConfigurationJSON {
    struct SyntaxFailure: LocalizedError {
        struct Location {
            let offset: Int, line: Int, column: Int
        }

        var location: Location? = nil
        var errorDescription: String? {
            guard let location else { return "JSON 格式有误。请检查括号、双引号和逗号。" }
            return "JSON 格式有误（第 \(location.line) 行，第 \(location.column) 列）"
        }
    }

    static func object(_ data: Data) throws -> [String: Any] {
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw SyntaxFailure() }
        guard let object = value as? [String: Any] else { throw PetError("配置需要一个 JSON 对象。") }
        return object
    }

    static func draftSyntaxFailure(after error: Error, in draft: String) -> SyntaxFailure? {
        let cocoa = error as NSError
        guard error is SyntaxFailure || (cocoa.domain == NSCocoaErrorDomain && cocoa.code == CocoaError.propertyListReadCorrupt.rawValue),
              draft.utf8.count <= 128_000 else { return nil }
        // A save can also parse an imported or on-disk file. Locate the error
        // only if the current draft itself fails, using its own parser offset.
        do { _ = try JSONSerialization.jsonObject(with: Data(draft.utf8), options: [.fragmentsAllowed]); return nil }
        catch {
            guard let bytes = (error as NSError).userInfo["NSJSONSerializationErrorIndex"] as? Int, bytes >= 0,
                  let byteIndex = draft.utf8.index(draft.utf8.startIndex, offsetBy: bytes, limitedBy: draft.utf8.endIndex),
                  let index = String.Index(byteIndex, within: draft) else { return SyntaxFailure() }
            var line = 1, column = 1
            for character in draft[..<index] {
                if character.isNewline { line += 1; column = 1 }
                else { column += 1 }
            }
            return SyntaxFailure(location: .init(offset: index.utf16Offset(in: draft), line: line, column: column))
        }
    }
}

// Keep the storage diagnostic intact for logs and tools; the UI presents the
// known cause without making users read an internal configuration path.
struct AgentSaveFailure: LocalizedError {
    enum Reason { case readOnly, changed, invalidLocation, invalidFile, exists, tooLarge }
    let reason: Reason
    let diagnostic: String
    var errorDescription: String? { diagnostic }
    var message: String {
        switch reason {
        case .readOnly: return "未保存：文件为只读。请恢复写入权限后重试。"
        case .changed: return "未保存：内容已在其他地方修改。请重新打开核对后再保存。"
        case .invalidLocation: return "未保存：保存位置已变化或包含链接。请重新打开后重试。"
        case .invalidFile: return "未保存：保存位置不是普通文件。请检查后重试。"
        case .exists: return "未保存：已有同名内容。请更换名称后重试。"
        case .tooLarge: return "未保存：内容超过大小上限。请缩短后重试。"
        }
    }

    static func message(for error: Error) -> String {
        if let failure = error as? AgentSaveFailure { return failure.message }
        var current = error as NSError
        // NSError may wrap the actual file-system cause. Bound traversal even
        // for malformed or cyclic errors supplied by an external service.
        for _ in 0..<8 {
            if current.domain == NSCocoaErrorDomain {
                switch CocoaError.Code(rawValue: current.code) {
                case .fileWriteNoPermission: return "未保存：没有写入权限。请检查文件及所在文件夹的权限后重试。"
                case .fileWriteVolumeReadOnly: return "未保存：磁盘为只读。请选择可写的位置后重试。"
                case .fileWriteOutOfSpace: return "未保存：磁盘空间不足。请释放空间后重试。"
                case .fileNoSuchFile, .fileReadNoSuchFile: return "未保存：保存位置不可用。请确认文件夹或外置磁盘已连接后重试。"
                case .fileWriteFileExists: return "未保存：已有同名内容。请更换名称后重试。"
                case .fileWriteInvalidFileName: return "未保存：文件名无效。请更换名称后重试。"
                default: break
                }
            }
            if current.domain == NSPOSIXErrorDomain, let code = POSIXErrorCode(rawValue: Int32(current.code)) {
                switch code {
                case .EACCES, .EPERM: return "未保存：没有写入权限。请检查文件及所在文件夹的权限后重试。"
                case .EROFS: return "未保存：磁盘为只读。请选择可写的位置后重试。"
                case .ENOSPC, .EDQUOT: return "未保存：磁盘空间不足。请释放空间后重试。"
                case .ENOENT, .ENODEV, .ENXIO, .ESTALE: return "未保存：保存位置不可用。请确认文件夹或外置磁盘已连接后重试。"
                case .EEXIST: return "未保存：已有同名内容。请更换名称后重试。"
                case .ENAMETOOLONG: return "未保存：名称或路径过长。请缩短后重试。"
                case .EBUSY, .EAGAIN, .EINTR: return "未保存：文件暂时不可用。请稍后重试。"
                default: break
                }
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        // Validation and partial-success messages already describe the actual
        // outcome. Never infer a cause by matching words in an error string.
        if error is PetError { return error.localizedDescription }
        let value = error as NSError
        let isFileError = value.domain == NSPOSIXErrorDomain || value.domain == NSCocoaErrorDomain && (0...1023).contains(value.code)
        return isFileError ? "未能保存，请稍后重试。" : error.localizedDescription
    }
}
