//
//  ImageCache.swift
//  Kingfisher
//
//  Created by Wei Wang on 15/4/6.
//
//  Copyright (c) 2015 Wei Wang <onevcat@gmail.com>
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

import UIKit

/**
This notification will be sent when the disk cache got cleaned either there are cached files expired or the total size exceeding the max allowed size. The manually invoking of `clearDiskCache` method will not trigger this notification.

The `object` of this notification is the `ImageCache` object which sends the notification.

A list of removed hashes (files) could be retrieved by accessing the array under `KingfisherDiskCacheCleanedHashKey` key in `userInfo` of the notification object you received. By checking the array, you could know the hash codes of files are removed.

The main purpose of this notification is supplying a chance to maintain some necessary information on the cached files. See [this wiki](https://github.com/onevcat/Kingfisher/wiki/How-to-implement-ETag-based-304-(Not-Modified)-handling-in-Kingfisher) for a use case on it.
*/
public let KingfisherDidCleanDiskCacheNotification = "com.onevcat.Kingfisher.KingfisherDidCleanDiskCacheNotification"

/**
Key for array of cleaned hashes in `userInfo` of `KingfisherDidCleanDiskCacheNotification`.
*/
public let KingfisherDiskCacheCleanedHashKey = "com.onevcat.Kingfisher.cleanedHash"

private let defaultCacheName = "default"
private let cacheReverseDNS = "com.onevcat.Kingfisher.ImageCache."
private let ioQueueName = "com.onevcat.Kingfisher.ImageCache.ioQueue."
private let processQueueName = "com.onevcat.Kingfisher.ImageCache.processQueue."

private let defaultCacheInstance = ImageCache(name: defaultCacheName)
private let defaultMaxCachePeriodInSecond: NSTimeInterval = 60 * 60 * 24 * 7 //Cache exists for 1 week

/// It represents a task of retrieving image. You can call `cancel` on it to stop the process.
public typealias RetrieveImageDiskTask = dispatch_block_t

/**
Cache type of a cached image.

- None:   The image is not cached yet when retrieving it.
- Memory: The image is cached in memory.
- Disk:   The image is cached in disk.
*/
public enum CacheType {
    case None, Memory, Disk
}

/// `ImageCache` represents both the memory and disk cache system of Kingfisher. While a default image cache object will be used if you prefer the extension methods of Kingfisher, you can create your own cache object and configure it as your need. You should use an `ImageCache` object to manipulate memory and disk cache for Kingfisher.
public class ImageCache {

    class IORunner: NSObject {
        
        class StoreImagePayload: NSObject {
            let image: UIImage
            let originalData: NSData?
            let key: String
            let handler: ()->()
            init(image: UIImage, originalData: NSData?, key: String, handler: ()->()) {
                self.image = image
                self.originalData = originalData
                self.key = key
                self.handler = handler
            }
        }
        
        class RemoveImagePayload: NSObject {
            let key: String
            let handler: ()->()
            init(key: String, handler: ()->()) {
                self.key = key
                self.handler = handler
            }
        }
        
        class RetrieveImagePayload: NSObject {
            let key: String
            let options: KingfisherManager.Options
            let handler: (UIImage?, CacheType?)->()
            init(key: String, options: KingfisherManager.Options, handler: (UIImage?, CacheType?)->()) {
                self.key = key
                self.options = options
                self.handler = handler
            }
        }
        
        class ClearDiskCachePayload: NSObject {
            let handler: ()->()
            init(handler: ()->()) {
                self.handler = handler
            }
        }
        
        class CleanExpiredDiskCachePayload: NSObject {
            let handler: ()->()
            init(handler: ()->()) {
                self.handler = handler
            }
        }
        
        class CalculateDiskCacheSizePayload: NSObject {
            let handler: (UInt)->()
            init(handler: (UInt)->()) {
                self.handler = handler
            }
        }
        
        var fileManager: NSFileManager!
        private weak var imageCache: ImageCache?
        
        func startRunLoop() {
            autoreleasepool {
                NSRunLoop.currentRunLoop().run()
            }
        }
        
        func setupFileManager() {
            fileManager = NSFileManager.defaultManager()
        }
        
        func storeImage(payload: StoreImagePayload) {
            
            guard let imageCache = imageCache else {
                runOnMainThread {
                    payload.handler()
                }
                return
            }
            
            let imageFormat: ImageFormat
            if let originalData = payload.originalData {
                imageFormat = originalData.kf_imageFormat
            } else {
                imageFormat = .Unknown
            }
            
            let data: NSData?
            switch imageFormat {
            case .PNG: data = UIImagePNGRepresentation(payload.image)
            case .JPEG: data = UIImageJPEGRepresentation(payload.image, 1.0)
            case .GIF: data = UIImageGIFRepresentation(payload.image)
            case .Unknown: data = payload.originalData ?? UIImagePNGRepresentation(payload.image.kf_normalizedImage())
            }
            
            if let data = data {
                if !self.fileManager.fileExistsAtPath(imageCache.diskCachePath) {
                    do {
                        try self.fileManager.createDirectoryAtPath(imageCache.diskCachePath, withIntermediateDirectories: true, attributes: nil)
                    } catch _ {}
                }
                
                self.fileManager.createFileAtPath(imageCache.cachePathForKey(payload.key), contents: data, attributes: nil)
            }
            
            runOnMainThread {
                payload.handler()
            }
        }
        
        func removeImage(payload: RemoveImagePayload) {
            guard let imageCache = imageCache else {
                runOnMainThread {
                    payload.handler()
                }
                return
            }
            
            do {
                try self.fileManager.removeItemAtPath(imageCache.cachePathForKey(payload.key))
            } catch _ {}
            runOnMainThread {
                payload.handler()
            }
        }
        
        func retrieveImage(payload: RetrieveImagePayload) {
            // We can ensure the image cache object exists since it is strongfied.
            // But we just guard it for defense
            guard let imageCache = imageCache else {
                runOnMainThread {
                    payload.handler(nil, nil)
                }
                assertionFailure("The code should not be executed here. If you encountered this, please fire an issue for it: https://github.com/onevcat/Kingfisher/issues/new")
                return
            }
            
            if let image = imageCache.retrieveImageInDiskCacheForKey(payload.key, scale: payload.options.scale) {
                if payload.options.shouldDecode {
                    dispatch_async(imageCache.processQueue, { () -> Void in
                        let result = image.kf_decodedImage(scale: payload.options.scale)
                        imageCache.storeImage(result!, forKey: payload.key, toDisk: false, completionHandler: nil)
                        self.runOnMainThread {
                            payload.handler(result, .Memory)
                        }
                    })
                } else {
                    imageCache.storeImage(image, forKey: payload.key, toDisk: false, completionHandler: nil)
                    self.runOnMainThread {
                        payload.handler(image, .Disk)
                    }
                }
            } else {
                // No image found from either memory or disk
                runOnMainThread {
                    payload.handler(nil, nil)
                }
            }
        }
        
        func clearDiskCache(payload: ClearDiskCachePayload) {
            guard let imageCache = imageCache else {
                runOnMainThread {
                    payload.handler()
                }
                return
            }
            
            do {
                try self.fileManager.removeItemAtPath(imageCache.diskCachePath)
                try self.fileManager.createDirectoryAtPath(imageCache.diskCachePath, withIntermediateDirectories: true, attributes: nil)
            } catch _ {
            }
            runOnMainThread {
                payload.handler()
            }
        }
        
        func cleanExpiredDiskCache(payload: CleanExpiredDiskCachePayload) {
            guard let imageCache = imageCache else {
                runOnMainThread {
                    payload.handler()
                }
                return
            }
            
            let diskCacheURL = NSURL(fileURLWithPath: imageCache.diskCachePath)
            let resourceKeys = [NSURLIsDirectoryKey, NSURLContentModificationDateKey, NSURLTotalFileAllocatedSizeKey]
            let expiredDate = NSDate(timeIntervalSinceNow: -imageCache.maxCachePeriodInSecond)
            var cachedFiles = [NSURL: [NSObject: AnyObject]]()
            var URLsToDelete = [NSURL]()
            
            var diskCacheSize: UInt = 0
            
            if let fileEnumerator = self.fileManager.enumeratorAtURL(diskCacheURL, includingPropertiesForKeys: resourceKeys, options: NSDirectoryEnumerationOptions.SkipsHiddenFiles, errorHandler: nil),
                urls = fileEnumerator.allObjects as? [NSURL] {
                    for fileURL in urls {
                        
                        do {
                            let resourceValues = try fileURL.resourceValuesForKeys(resourceKeys)
                            // If it is a Directory. Continue to next file URL.
                            if let isDirectory = resourceValues[NSURLIsDirectoryKey] as? NSNumber {
                                if isDirectory.boolValue {
                                    continue
                                }
                            }
                            
                            // If this file is expired, add it to URLsToDelete
                            if let modificationDate = resourceValues[NSURLContentModificationDateKey] as? NSDate {
                                if modificationDate.laterDate(expiredDate) == expiredDate {
                                    URLsToDelete.append(fileURL)
                                    continue
                                }
                            }
                            
                            if let fileSize = resourceValues[NSURLTotalFileAllocatedSizeKey] as? NSNumber {
                                diskCacheSize += fileSize.unsignedLongValue
                                cachedFiles[fileURL] = resourceValues
                            }
                        } catch _ {
                        }
                        
                    }
            }
            
            for fileURL in URLsToDelete {
                do {
                    try self.fileManager.removeItemAtURL(fileURL)
                } catch _ {
                }
            }
            
            if imageCache.maxDiskCacheSize > 0 && diskCacheSize > imageCache.maxDiskCacheSize {
                let targetSize = imageCache.maxDiskCacheSize / 2
                
                // Sort files by last modify date. We want to clean from the oldest files.
                let sortedFiles = cachedFiles.keysSortedByValue({ (resourceValue1, resourceValue2) -> Bool in
                    
                    if let date1 = resourceValue1[NSURLContentModificationDateKey] as? NSDate {
                        if let date2 = resourceValue2[NSURLContentModificationDateKey] as? NSDate {
                            return date1.compare(date2) == .OrderedAscending
                        }
                    }
                    // Not valid date information. This should not happen. Just in case.
                    return true
                })
                
                for fileURL in sortedFiles {
                    
                    do {
                        try self.fileManager.removeItemAtURL(fileURL)
                    } catch {
                        
                    }
                    
                    URLsToDelete.append(fileURL)
                    
                    if let fileSize = cachedFiles[fileURL]?[NSURLTotalFileAllocatedSizeKey] as? NSNumber {
                        diskCacheSize -= fileSize.unsignedLongValue
                    }
                    
                    if diskCacheSize < targetSize {
                        break
                    }
                }
            }
            
            runOnMainThread {
                if URLsToDelete.count != 0 {
                    let cleanedHashes = URLsToDelete.map({ (url) -> String in
                        return url.lastPathComponent!
                    })
                    
                    let notification = NSNotification(name: KingfisherDidCleanDiskCacheNotification, object: imageCache, userInfo: [KingfisherDiskCacheCleanedHashKey: cleanedHashes])
                    self.postNotificationOnMainThread(notification)
                }
                
                payload.handler()
            }
        }
        
        func postNotificationOnMainThread(notification: NSNotification) {
            NSNotificationCenter.defaultCenter().performSelectorOnMainThread("postNotification:", withObject: notification, waitUntilDone: true)
        }
        
        func calculateDiskCacheSize(payload: CalculateDiskCacheSizePayload) {
            
            guard let imageCache = imageCache else {
                runOnMainThread {
                    payload.handler(0)
                }
                return
            }
            
            let diskCacheURL = NSURL(fileURLWithPath: imageCache.diskCachePath)
            
            let resourceKeys = [NSURLIsDirectoryKey, NSURLTotalFileAllocatedSizeKey]
            var diskCacheSize: UInt = 0
            
            if let fileEnumerator = self.fileManager.enumeratorAtURL(diskCacheURL, includingPropertiesForKeys: resourceKeys, options: NSDirectoryEnumerationOptions.SkipsHiddenFiles, errorHandler: nil),
                urls = fileEnumerator.allObjects as? [NSURL] {
                    for fileURL in urls {
                        do {
                            let resourceValues = try fileURL.resourceValuesForKeys(resourceKeys)
                            // If it is a Directory. Continue to next file URL.
                            if let isDirectory = resourceValues[NSURLIsDirectoryKey]?.boolValue {
                                if isDirectory {
                                    continue
                                }
                            }
                            
                            if let fileSize = resourceValues[NSURLTotalFileAllocatedSizeKey] as? NSNumber {
                                diskCacheSize += fileSize.unsignedLongValue
                            }
                        } catch _ {
                        }
                        
                    }
            }
            
            runOnMainThread {
                payload.handler(diskCacheSize)
            }
        }
        
        func runOnMainThread(method: ()->()) {
            if NSThread.isMainThread() {
                method()
            } else {
                dispatch_sync(dispatch_get_main_queue(), method)
            }
        }
    }
    
    //Memory
    private let memoryCache = NSCache()
    
    /// The largest cache cost of memory cache. The total cost is pixel count of all cached images in memory.
    public var maxMemoryCost: UInt = 0 {
        didSet {
            self.memoryCache.totalCostLimit = Int(maxMemoryCost)
        }
    }
    
    //Disk
    // There is a bug on customize queue that leaking memory in iOS 9.2
    // So we do not reply on the queue any more. See http://openradar.appspot.com/23894846
    // private let ioQueue: dispatch_queue_t
    private let ioThread: NSThread!
    private let ioRunner = IORunner()
    
    ///The disk cache location.
    public let diskCachePath: String
    
    /// The longest time duration of the cache being stored in disk. Default is 1 week.
    public var maxCachePeriodInSecond = defaultMaxCachePeriodInSecond
    
    /// The largest disk size can be taken for the cache. It is the total allocated size of cached files in bytes. Default is 0, which means no limit.
    public var maxDiskCacheSize: UInt = 0
    
    private let processQueue: dispatch_queue_t
    
    /// The default cache.
    public class var defaultCache: ImageCache {
        return defaultCacheInstance
    }
    
    /**
    Init method. Passing a name for the cache. It represents a cache folder in the memory and disk.
    
    - parameter name: Name of the cache. It will be used as the memory cache name and the disk cache folder name appending to the cache path. This value should not be an empty string.
    - parameter path: Optional - Location of cache path on disk. If `nil` is passed (the default value), 
                      the cache folder in of your app will be used. If you want to cache some user generating images, you could pass the Documentation path here.
    
    - returns: The cache object.
    */
    public init(name: String, path: String? = nil) {
        
        if name.isEmpty {
            fatalError("[Kingfisher] You should specify a name for the cache. A cache with empty name is not permitted.")
        }
        
        let cacheName = cacheReverseDNS + name
        memoryCache.name = cacheName
        
        let dstPath = path ?? NSSearchPathForDirectoriesInDomains(.CachesDirectory, NSSearchPathDomainMask.UserDomainMask, true).first!
        diskCachePath = (dstPath as NSString).stringByAppendingPathComponent(cacheName)
        
        ioThread = NSThread(target: ioRunner, selector: "startRunLoop", object: nil)
        ioThread.start()

        processQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)
        
        ioRunner.imageCache = self
        ioRunner.performSelector("setupFileManager", onThread: ioThread, withObject: nil, waitUntilDone: false)
        
        NSNotificationCenter.defaultCenter().addObserver(self, selector: "clearMemoryCache", name: UIApplicationDidReceiveMemoryWarningNotification, object: nil)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: "cleanExpiredDiskCache", name: UIApplicationWillTerminateNotification, object: nil)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: "backgroundCleanExpiredDiskCache", name: UIApplicationDidEnterBackgroundNotification, object: nil)
    }
    
    deinit {
        NSNotificationCenter.defaultCenter().removeObserver(self)
    }
}

// MARK: - Store & Remove
public extension ImageCache {
    /**
    Store an image to cache. It will be saved to both memory and disk. 
    It is an async operation, if you need to do something about the stored image, use `-storeImage:forKey:toDisk:completionHandler:` 
    instead.
    
    - parameter image:        The image will be stored.
    - parameter originalData: The original data of the image.
                              Kingfisher will use it to check the format of the image and optimize cache size on disk.
                              If `nil` is supplied, the image data will be saved as a normalized PNG file.
                              It is strongly suggested to supply it whenever possible, to get a better performance and disk usage.
    - parameter key:          Key for the image.
    */
    public func storeImage(image: UIImage, originalData: NSData? = nil, forKey key: String) {
        storeImage(image, originalData: originalData, forKey: key, toDisk: true, completionHandler: nil)
    }
    
    /**
    Store an image to cache. It is an async operation.
    
    - parameter image:             The image will be stored.
    - parameter originalData:      The original data of the image.
                                   Kingfisher will use it to check the format of the image and optimize cache size on disk.
                                   If `nil` is supplied, the image data will be saved as a normalized PNG file. 
                                   It is strongly suggested to supply it whenever possible, to get a better performance and disk usage.
    - parameter key:               Key for the image.
    - parameter toDisk:            Whether this image should be cached to disk or not. If false, the image will be only cached in memory.
    - parameter completionHandler: Called when stroe operation completes.
    */
    public func storeImage(image: UIImage, originalData: NSData? = nil, forKey key: String, toDisk: Bool, completionHandler: (() -> ())?) {
        memoryCache.setObject(image, forKey: key, cost: image.kf_imageCost)
        
        func callHandlerInMainQueue() {
            if let handler = completionHandler {
                handler()
            }
        }
        
        if toDisk {
            let payload = IORunner.StoreImagePayload(image: image, originalData: originalData, key: key, handler: callHandlerInMainQueue)
            ioRunner.performSelector("storeImage:", onThread: ioThread, withObject: payload, waitUntilDone: false)
        } else {
            callHandlerInMainQueue()
        }
    }
    
    /**
    Remove the image for key for the cache. It will be opted out from both memory and disk.
    It is an async operation, if you need to do something about the stored image, use `-removeImageForKey:fromDisk:completionHandler:` 
    instead.
    
    - parameter key: Key for the image.
    */
    public func removeImageForKey(key: String) {
        removeImageForKey(key, fromDisk: true, completionHandler: nil)
    }
    
    /**
    Remove the image for key for the cache. It is an async operation.
    
    - parameter key:               Key for the image.
    - parameter fromDisk:          Whether this image should be removed from disk or not. If false, the image will be only removed from memory.
    - parameter completionHandler: Called when removal operation completes.
    */
    public func removeImageForKey(key: String, fromDisk: Bool, completionHandler: (() -> ())?) {
        memoryCache.removeObjectForKey(key)
        
        func callHandlerInMainQueue() {
            if let handler = completionHandler {
                handler()
            }
        }
        
        if fromDisk {
            let payload = IORunner.RemoveImagePayload(key: key, handler: callHandlerInMainQueue)
            ioRunner.performSelector("removeImage:", onThread: ioThread, withObject: payload, waitUntilDone: false)
        } else {
            callHandlerInMainQueue()
        }
    }
    
}

// MARK: - Get data from cache
extension ImageCache {
    /**
    Get an image for a key from memory or disk.
    
    - parameter key:               Key for the image.
    - parameter options:           Options of retrieving image.
    - parameter completionHandler: Called when getting operation completes with image result and cached type of this image. If there is no such key cached, the image will be `nil`.
    
    - returns: The retrieving task.
    */
    public func retrieveImageForKey(key: String, options: KingfisherManager.Options, completionHandler: ((UIImage?, CacheType!) -> ())?) -> RetrieveImageDiskTask? {
        // No completion handler. Not start working and early return.
        guard let completionHandler = completionHandler else {
            return nil
        }
        
        var block: RetrieveImageDiskTask?
        if let image = self.retrieveImageInMemoryCacheForKey(key) {
            
            //Found image in memory cache.
            if options.shouldDecode {
                dispatch_async(self.processQueue, { () -> Void in
                    let result = image.kf_decodedImage(scale: options.scale)
                    dispatch_async(options.queue, { () -> Void in
                        completionHandler(result, .Memory)
                    })
                })
            } else {
                completionHandler(image, .Memory)
            }
        } else {
            var sSelf: ImageCache! = self
            
            let handler: (UIImage?, CacheType?) -> () = {
                image, type in
                dispatch_async(options.queue, { () -> Void in
                    completionHandler(image, type)
                    sSelf = nil
                })
            }
            
            block = dispatch_block_create(DISPATCH_BLOCK_INHERIT_QOS_CLASS) {
                let payload = IORunner.RetrieveImagePayload(key: key, options: options, handler: handler)
                sSelf.ioRunner.performSelector("retrieveImage:", onThread: sSelf.ioThread, withObject: payload, waitUntilDone: false)
            }
            
            dispatch_async(dispatch_get_main_queue(), block!)
        }
    
        return block
    }
    
    /**
    Get an image for a key from memory.
    
    - parameter key: Key for the image.
    
    - returns: The image object if it is cached, or `nil` if there is no such key in the cache.
    */
    public func retrieveImageInMemoryCacheForKey(key: String) -> UIImage? {
        return memoryCache.objectForKey(key) as? UIImage
    }
    
    /**
    Get an image for a key from disk.
    
    - parameter key: Key for the image.
    - param scale: The scale factor to assume when interpreting the image data.

    - returns: The image object if it is cached, or `nil` if there is no such key in the cache.
    */
    public func retrieveImageInDiskCacheForKey(key: String, scale: CGFloat = KingfisherManager.DefaultOptions.scale) -> UIImage? {
        return diskImageForKey(key, scale: scale)
    }
}

// MARK: - Clear & Clean
extension ImageCache {
    /**
    Clear memory cache.
    */
    @objc public func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }
    
    /**
    Clear disk cache. This is an async operation.
    */
    public func clearDiskCache() {
        clearDiskCacheWithCompletionHandler(nil)
    }
    
    /**
    Clear disk cache. This is an async operation.
    
    - parameter completionHandler: Called after the operation completes.
    */
    public func clearDiskCacheWithCompletionHandler(completionHandler: (()->())?) {
        
        let handler: ()->() = {
            if let completionHandler = completionHandler {
                completionHandler()
            }
        }
    
        let payload = IORunner.ClearDiskCachePayload(handler: handler)
        ioRunner.performSelector("clearDiskCache:", onThread: ioThread, withObject: payload, waitUntilDone: false)
    }
    
    /**
    Clean expired disk cache. This is an async operation.
    */
    @objc public func cleanExpiredDiskCache() {
        cleanExpiredDiskCacheWithCompletionHander(nil)
    }
    
    /**
    Clean expired disk cache. This is an async operation.
    
    - parameter completionHandler: Called after the operation completes.
    */
    public func cleanExpiredDiskCacheWithCompletionHander(completionHandler: (()->())?) {
        let handler: ()->() = {
            if let completionHandler = completionHandler {
                completionHandler()
            }
        }
        let payload = IORunner.CleanExpiredDiskCachePayload(handler: handler)
        ioRunner.performSelector("cleanExpiredDiskCache:", onThread: ioThread, withObject: payload, waitUntilDone: false)
    }
    
    /**
    Clean expired disk cache when app in background. This is an async operation.
    In most cases, you should not call this method explicitly. 
    It will be called automatically when `UIApplicationDidEnterBackgroundNotification` received.
    */
    @objc public func backgroundCleanExpiredDiskCache() {
        
        func endBackgroundTask(inout task: UIBackgroundTaskIdentifier) {
            UIApplication.sharedApplication().endBackgroundTask(task)
            task = UIBackgroundTaskInvalid
        }
        
        var backgroundTask: UIBackgroundTaskIdentifier!
        
        backgroundTask = UIApplication.sharedApplication().beginBackgroundTaskWithExpirationHandler { () -> Void in
            endBackgroundTask(&backgroundTask!)
        }
        
        cleanExpiredDiskCacheWithCompletionHander { () -> () in
            endBackgroundTask(&backgroundTask!)
        }
    }
}


// MARK: - Check cache status
public extension ImageCache {
    
    /**
    *  Cache result for checking whether an image is cached for a key.
    */
    public struct CacheCheckResult {
        public let cached: Bool
        public let cacheType: CacheType?
    }
    
    /**
    Check whether an image is cached for a key.
    
    - parameter key: Key for the image.
    
    - returns: The check result.
    */
    public func isImageCachedForKey(key: String) -> CacheCheckResult {
        
        if memoryCache.objectForKey(key) != nil {
            return CacheCheckResult(cached: true, cacheType: .Memory)
        }
        
        let filePath = cachePathForKey(key)
        
        if NSFileManager.defaultManager().fileExistsAtPath(filePath) {
            return CacheCheckResult(cached: true, cacheType: .Disk)
        }
        
        return CacheCheckResult(cached: false, cacheType: nil)
    }
    
    /**
    Get the hash for the key. This could be used for matching files.
    
    - parameter key: The key which is used for caching.
    
    - returns: Corresponding hash.
    */
    public func hashForKey(key: String) -> String {
        return cacheFileNameForKey(key)
    }
    
    /**
    Calculate the disk size taken by cache. 
    It is the total allocated size of the cached files in bytes.
    
    - parameter completionHandler: Called with the calculated size when finishes.
    */
    public func calculateDiskCacheSizeWithCompletionHandler(completionHandler: ((size: UInt) -> ())?) {
        
        let handler: (UInt)->() = {
            size in
            if let completionHandler = completionHandler {
                completionHandler(size: size)
            }
        }
        
        let payload = IORunner.CalculateDiskCacheSizePayload(handler: handler)
        ioRunner.performSelector("calculateDiskCacheSize", onThread: ioThread, withObject: payload, waitUntilDone: false)
    }
}

// MARK: - Internal Helper
extension ImageCache {
    
    func diskImageForKey(key: String, scale: CGFloat) -> UIImage? {
        if let data = diskImageDataForKey(key) {
            return UIImage.kf_imageWithData(data, scale: scale)
        } else {
            return nil
        }
    }
    
    func diskImageDataForKey(key: String) -> NSData? {
        let filePath = cachePathForKey(key)
        return NSData(contentsOfFile: filePath)
    }
    
    func cachePathForKey(key: String) -> String {
        let fileName = cacheFileNameForKey(key)
        return (diskCachePath as NSString).stringByAppendingPathComponent(fileName)
    }
    
    func cacheFileNameForKey(key: String) -> String {
        return key.kf_MD5()
    }
}

extension UIImage {
    var kf_imageCost: Int {
        return images == nil ?
            Int(size.height * size.width * scale * scale) :
            Int(size.height * size.width * scale * scale) * images!.count
    }
}

extension Dictionary {
    func keysSortedByValue(isOrderedBefore: (Value, Value) -> Bool) -> [Key] {
        var array = Array(self)
        array.sortInPlace {
            let (_, lv) = $0
            let (_, rv) = $1
            return isOrderedBefore(lv, rv)
        }
        return array.map {
            let (k, _) = $0
            return k
        }
    }
}
