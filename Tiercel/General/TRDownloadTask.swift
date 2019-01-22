//
//  TRDownloadTask.swift
//  Tiercel
//
//  Created by Daniels on 2018/3/16.
//  Copyright © 2018年 Daniels. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import UIKit

public class TRDownloadTask: TRTask {

    internal var task: URLSessionDownloadTask? {
        didSet {
            task?.addObserver(self, forKeyPath: "currentRequest", options: [.new], context: nil)
        }
    }

    public var filePath: String {
        return cache.filePtah(fileName: fileName)!
    }
    
    internal var tmpFileURL: URL?

    private var resumeData: Data? {
        didSet {
            guard let resumeData = resumeData else { return  }
            tmpFileName = TRResumeDataHelper.getTmpFileName(resumeData)
        }
    }
    
    internal var tmpFileName: String?

    public init(_ url: URL,
                fileName: String? = nil,
                cache: TRCache,
                verificationCode: String? = nil,
                verificationType: TRVerificationType = .md5,
                progressHandler: TRTaskHandler? = nil,
                successHandler: TRTaskHandler? = nil,
                failureHandler: TRTaskHandler? = nil) {
        super.init(url,
                   cache: cache,
                   verificationCode: verificationCode,
                   verificationType: verificationType,
                   progressHandler: progressHandler,
                   successHandler: successHandler,
                   failureHandler: failureHandler)
        if let fileName = fileName,
            !fileName.isEmpty {
            self.fileName = fileName
        }
        NotificationCenter.default.addObserver(self, selector: #selector(fixDelegateMethodError), name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    
    public override func encode(with aCoder: NSCoder) {
        super.encode(with: aCoder)
        aCoder.encode(resumeData, forKey: "resumeData")
    }
    
    public required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        resumeData = aDecoder.decodeObject(forKey: "resumeData") as? Data
        guard let resumeData = resumeData else { return  }
        tmpFileName = TRResumeDataHelper.getTmpFileName(resumeData)
    }
    
    deinit {
        task?.removeObserver(self, forKeyPath: "currentRequest")
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func fixDelegateMethodError() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.task?.suspend()
            self.task?.resume()
        }
    }
    
// MARK: - control
    internal override func start() {
        cache.createDirectory()
        
        task?.removeObserver(self, forKeyPath: "currentRequest")
        if let resumeData = resumeData {
            cache.retrievTmpFile(self)
            if #available(iOS 10.2, *) {
                task = session?.downloadTask(withResumeData: resumeData)
            } else if #available(iOS 10.0, *) {
                task = session?.correctedDownloadTask(withResumeData: resumeData)
            } else {
                task = session?.downloadTask(withResumeData: resumeData)
            }
        } else {
            super.start()
            guard let request = request else { return  }
            task = session?.downloadTask(with: request)
        }
        speed = 0
        progress.setUserInfoObject(progress.completedUnitCount, forKey: .fileCompletedCountKey)
        
        task?.resume()

        if startDate == 0 {
            startDate = Date().timeIntervalSince1970
        }
        status = .running
        TiercelLog("[downloadTask] runing, manager.identifier: \(manager?.identifier ?? ""), URLString: \(URLString)")
    }


    internal override func suspend(_ handler: TRTaskHandler? = nil) {
        guard status == .running || status == .waiting else { return }
        controlHandler = handler

        if status == .running {
            status = .willSuspend
            task?.cancel(byProducingResumeData: { _ in })
        }

        if status == .waiting {
            status = .suspended
            TiercelLog("[downloadTask] did suspend, manager.identifier: \(manager?.identifier ?? ""), URLString: \(URLString)")
            DispatchQueue.main.tr.safeAsync {
                self.progressHandler?(self)
                self.controlHandler?(self)
                self.failureHandler?(self)
            }
            manager?.completed()
        }
    }
    
    internal override func cancel(_ handler: TRTaskHandler? = nil) {
        guard status != .completed else { return }
        controlHandler = handler
        
        if status == .running {
            status = .willCancel
            task?.cancel()
        } else {
            status = .willCancel
            manager?.taskDidCancelOrRemove(URLString)
            TiercelLog("[downloadTask] did cancel, manager.identifier: \(manager?.identifier ?? ""), URLString: \(URLString)")

            DispatchQueue.main.tr.safeAsync {
                self.controlHandler?(self)
                self.failureHandler?(self)
            }
            manager?.completed()
        }
        
    }


    internal override func remove(_ handler: TRTaskHandler? = nil) {
        controlHandler = handler

        if status == .running {
            status = .willRemove
            task?.cancel()
        } else {
            status = .willRemove
            manager?.taskDidCancelOrRemove(URLString)
            TiercelLog("[downloadTask] did remove, manager.identifier: \(manager?.identifier ?? ""), URLString: \(URLString)")
            DispatchQueue.main.tr.safeAsync {
                self.controlHandler?(self)
                self.failureHandler?(self)
            }
            manager?.completed()
        }
    }
    
    internal override func completed() {
        guard status != .completed else { return }
        status = .completed
        endDate = Date().timeIntervalSince1970
        progress.completedUnitCount = progress.totalUnitCount
        timeRemaining = 0
        TiercelLog("[downloadTask] completed, manager.identifier: \(manager?.identifier ?? ""), URLString: \(URLString)")

        DispatchQueue.main.tr.safeAsync {
            self.progressHandler?(self)
            self.successHandler?(self)
        }

        if let verificationCode = verificationCode {
            status = .willValidate
            TRChecksumHelper.validateFile(filePath, verificationCode: verificationCode, verificationType: verificationType) { [weak self] (isCorrect) in
                guard let strongSelf = self else { return }
                strongSelf.status = .validated
                if isCorrect {
                    DispatchQueue.main.tr.safeAsync {
                        strongSelf.successHandler?(strongSelf)
                    }
                } else {
                    DispatchQueue.main.tr.safeAsync {
                        strongSelf.failureHandler?(strongSelf)
                    }
                }
            }
        }

    }

}


// MARK: - KVO
extension TRDownloadTask {
    override public func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if let change = change, let newRequest = change[NSKeyValueChangeKey.newKey] as? URLRequest, let url = newRequest.url {
            currentURLString = url.absoluteString
        }
    }
}

// MARK: - info
extension TRDownloadTask {

    internal func updateSpeedAndTimeRemaining(_ cost: TimeInterval) {

        let dataCount = progress.completedUnitCount
        let lastData: Int64 = progress.userInfo[.fileCompletedCountKey] as? Int64 ?? 0

        if dataCount > lastData {
            speed = Int64(Double(dataCount - lastData) / cost)
            updateTimeRemaining()
        }
        progress.setUserInfoObject(dataCount, forKey: .fileCompletedCountKey)

    }

    private func updateTimeRemaining() {
        if speed == 0 {
            self.timeRemaining = 0
        } else {
            let timeRemaining = (Double(progress.totalUnitCount) - Double(progress.completedUnitCount)) / Double(speed)
            self.timeRemaining = Int64(timeRemaining)
            if timeRemaining < 1 && timeRemaining > 0.8 {
                self.timeRemaining += 1
            }
        }
    }
}

// MARK: - download callback
extension TRDownloadTask {
    internal func didWriteData(bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress.completedUnitCount = totalBytesWritten
        progress.totalUnitCount = totalBytesExpectedToWrite
        manager?.updateSpeedAndTimeRemaining()
        DispatchQueue.main.tr.safeAsync {
            if TRManager.isControlNetworkActivityIndicator {
                UIApplication.shared.isNetworkActivityIndicatorVisible = true
            }
            self.progressHandler?(self)
            self.manager?.updateProgress()
        }
    }
    
    
    internal func didFinishDownloadingTo(location: URL) {
        self.tmpFileURL = location
        cache.storeFile(self)
        cache.removeTmpFile(self)
    }
    
    internal func didComplete(task: URLSessionTask, error: Error?) {
        if TRManager.isControlNetworkActivityIndicator {
            DispatchQueue.main.tr.safeAsync {
                UIApplication.shared.isNetworkActivityIndicatorVisible = false
            }
        }

        session = nil
        progress.totalUnitCount = task.countOfBytesExpectedToReceive
        progress.completedUnitCount = task.countOfBytesReceived
        
        if let error = error {
            self.error = error
        
            if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                self.resumeData = TRResumeDataHelper.handleResumeData(resumeData)
                cache.storeTmpFile(self)
            }
            if let _ = (error as NSError).userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? Int {
                status = .suspended
            }
            if let urlError = error as? URLError, urlError.code != URLError.cancelled {
                status = .failed
            }
            
            switch status {
            case .suspended:
                status = .suspended
                TiercelLog("[downloadTask] did suspend, manager.identifier: \(manager?.identifier ?? ""), URLString: \(URLString)")

            case .willSuspend:
                status = .suspended
                TiercelLog("[downloadTask] did suspend, manager.identifier: \(manager?.identifier ?? ""), URLString: \(URLString)")

                DispatchQueue.main.tr.safeAsync {
                    self.progressHandler?(self)
                    self.controlHandler?(self)
                    self.failureHandler?(self)
                }
            case .willCancel, .willRemove:
                manager?.taskDidCancelOrRemove(URLString)
                if status == .canceled {
                    TiercelLog("[downloadTask] did cancel, manager.identifier: \(manager?.identifier ?? ""), URLString: \(URLString)")
                }
                if status == .removed {
                    TiercelLog("[downloadTask] did removed, manager.identifier: \(manager?.identifier ?? ""), URLString: \(URLString)")
                }
                DispatchQueue.main.tr.safeAsync {
                    self.controlHandler?(self)
                    self.failureHandler?(self)
                }
            default:
                status = .failed
                TiercelLog("[downloadTask] failed, manager.identifier: \(manager?.identifier ?? ""), URLString: \(URLString), error: \(error)")
                DispatchQueue.main.tr.safeAsync {
                    self.failureHandler?(self)
                }
            }
        } else {
            completed()
        }
        manager?.completed()
    }
}

