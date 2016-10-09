//
//  Controllers.swift
//  iDrag
//
//  Created by runforever on 16/10/3.
//  Copyright © 2016年 defcoding. All rights reserved.
//

import Cocoa

import Qiniu
import CryptoSwift
import SwiftyJSON
import PromiseKit

class DragUploadManager {

    let shareWorkspace = NSWorkspace.shared()
    let fileManager = FileManager()

    let domain = NSUserDefaultsController.shared().defaults.string(forKey: "domain")!
    let qiNiu = QNUploadManager()!

    var dragApp: NSStatusItem!
    var uploadImageView: UploadImageView!
    var userDefaults: UserDefaults!

    init(dragApp: NSStatusItem, uploadImageView: UploadImageView, userDefaults: UserDefaults) {
        self.dragApp = dragApp
        self.uploadImageView = uploadImageView
        self.userDefaults = userDefaults
    }

    func uploadFiles(filePaths: NSArray) {
        var uploadFiles: [Promise<UploadFileRow>] = []

        for path in filePaths {
            let filePath = path as! String
            uploadFiles.append(uploadFile(filePath: filePath))
        }

        when(fulfilled: uploadFiles).then { uploadRows -> Void in
            let maxDisplayCount = 9
            self.uploadImageView.uploadImageRows += uploadRows
            self.uploadImageView.uploadImageRows = self.uploadImageView.uploadImageRows.reversed()
            if self.uploadImageView.uploadImageRows.count > maxDisplayCount {
                self.uploadImageView.uploadImageRows = Array(self.uploadImageView.uploadImageRows[0..<maxDisplayCount])
            }
            self.uploadImageView.uploadImageTable.reloadData()
            let imageItem = self.dragApp.menu?.item(withTag: 1)!
            imageItem?.view = self.uploadImageView
            imageItem?.isHidden = true
            self.dragApp.button?.performClick(nil)
        }.catch(execute: {error in
            let failNotification = NSUserNotification()
            failNotification.title = "上传失败"
            failNotification.informativeText = "请检查设置是否正确"
            NSUserNotificationCenter.default.deliver(failNotification)
        }).always {
        }
    }

    func uploadFile(filePath: String) -> Promise<UploadFileRow> {
        return Promise {fulfill, reject in
            let fileType = try! shareWorkspace.type(ofFile: filePath)
            let fileAttr = try! fileManager.attributesOfItem(atPath: filePath) as NSDictionary
            let fileSize = fileAttr.fileSize()
            let filename = NSURL(fileURLWithPath: filePath).lastPathComponent!
            let compressState = userDefaults.integer(forKey: CompressSettingKey)

            let token = createQiniuToken(filename: filename)
            let imageNeedCompress = CompressFileTypes.contains(fileType) && fileSize > MaxImageSize && compressState == NSOnState

            if imageNeedCompress {
                let imageData = createCompressImageData(filePath: filePath)
                qiNiu.put(imageData, key: filename, token: token, complete: {info, key, resp -> Void in
                    switch info?.statusCode {
                    case Int32(200)?:
                        let uploadFileRow = self.createUploadFileRow(filename: key!, filePath: filePath, fileType: fileType)
                        fulfill(uploadFileRow)
                    default:
                        reject((info?.error)!)
                    }
                    }, option: nil)
            }
            else {
                qiNiu.putFile(filePath, key: filename, token: token, complete: {info, key, resp -> Void in
                    switch info?.statusCode {
                    case Int32(200)?:
                        let uploadFileRow = self.createUploadFileRow(filename: key!, filePath: filePath, fileType: fileType)
                        fulfill(uploadFileRow)
                    default:
                        reject((info?.error)!)
                    }
                    }, option: nil)
            }

        }
    }

    func createCompressImageData(filePath: String) -> Data {
        let image = NSImage(contentsOfFile: filePath)!
        let bitmapImageRep = NSBitmapImageRep(data: image.tiffRepresentation!)
        let compressOption:NSDictionary = [NSImageCompressionFactor: 0.3]
        let imageData = bitmapImageRep?.representation(using: NSJPEGFileType, properties: compressOption as! [String : Any])
        return imageData!
    }

    func createQiniuToken(filename: String) -> String {
        let userDefaults = NSUserDefaultsController.shared().defaults
        let accessKey = userDefaults.string(forKey: "accessKey")!
        let secretKey = userDefaults.string(forKey: "secretKey")!
        let bucket = userDefaults.string(forKey: "bucket")!
        let deadline = round(NSDate(timeIntervalSinceNow: 3600).timeIntervalSince1970)
        let putPolicyDict:JSON = [
            "scope": "\(bucket):\(filename)",
            "deadline": deadline,
            ]

        let b64PutPolicy = QNUrlSafeBase64.encode(putPolicyDict.rawString()!)!
        let secretSign =  try! HMAC(key: (secretKey.utf8.map({$0})), variant: .sha1).authenticate((b64PutPolicy.utf8.map({$0})))
        let b64SecretSign = QNUrlSafeBase64.encode(Data(bytes: secretSign))!

        let putPolicy:String = [accessKey, b64SecretSign, b64PutPolicy].joined(separator: ":")
        return putPolicy
    }

    func createUploadFileRow(filename: String, filePath: String, fileType: String) -> UploadFileRow {
        let imageUrl = "\(self.domain)/\(filename)"
        let fileIcon = { () -> NSImage in
            if ImageFileTypes.contains(fileType) {
                return NSImage(contentsOfFile: filePath)!
            }
            else {
                return self.shareWorkspace.icon(forFile: filePath)
            }
        }()

        let uploadFileRow = UploadFileRow(image: fileIcon, url: imageUrl, filename: filename)
        return uploadFileRow
    }
}
