import os
import SwiftUI

class DownloadManager: NSObject, ObservableObject {
    static var shared = DownloadManager()

    private var urlSession: URLSession!
    @Published var tasks: [URLSessionTask] = []

    override private init() {
        super.init()

        let config = URLSessionConfiguration.background(withIdentifier: "\(Bundle.main.bundleIdentifier!).background")

        // Warning: Make sure that the URLSession is created only once (if an URLSession still
        // exists from a previous download, it doesn't create a new URLSession object but returns
        // the existing one with the old delegate object attached)

        // Serial delegate queue: game archives are moved/unzipped into the shared
        // Documents directory, so completions must not run concurrently.
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)

        updateTasks()
    }

    func startDownload(url: URL) {
        let task = urlSession.downloadTask(with: url)
        print(url.lastPathComponent)
        task.resume()
        tasks.append(task)
    }

    private func updateTasks() {
        urlSession.getAllTasks { tasks in
            DispatchQueue.main.async {
                self.tasks = tasks
            }
        }
    }
}

extension DownloadManager: URLSessionDelegate, URLSessionDownloadDelegate {
    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten _: Int64, totalBytesExpectedToWrite _: Int64) {
        os_log("Progress %f for %@", type: .debug, downloadTask.progress.fractionCompleted, downloadTask)
    }

    fileprivate func downloadGamesList(_ location: URL) throws {
        print("Got GamesList")

        let destinationUrl = URL(fileURLWithPath: documentsDirectory.relativePath + "/allfiles.txt")
        _ = FileManager.default.secureCopyItem(at: location, to: destinationUrl)

        do {
            let data = try String(contentsOfFile: destinationUrl.relativePath, encoding: .utf8)
            games2Download = data.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: "receivedGameList"), object: nil)
        } catch {
            print(error)
        }
    }

    fileprivate func downloadGame(_ location: URL, named fileName: String) throws {

        // Each archive gets its own destination so parallel downloads
        // don't overwrite each other.
        let destinationUrl = documentsDirectory.appendingPathComponent(fileName)
        FileManager.default.removeIfExists(srcURL: destinationUrl)
        try FileManager.default.moveItem(at: location, to: destinationUrl)

        if fileName.hasSuffix("zip")
        {
            try ZipExtractor.extract(destinationUrl, to: documentsDirectory)
            try FileManager.default.removeItem(at: destinationUrl)
        }
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: "receivedGame"), object: nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let httpResponse = downloadTask.response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode) else {
                print ("server error")
                return
        }

        // Dispatch on the finished task's own URL; a shared "current file"
        // variable would be wrong with overlapping downloads.
        guard let fileName = downloadTask.originalRequest?.url?.lastPathComponent else {
            print("download finished without a request URL")
            return
        }

        do {
            if(fileName == "allfiles.txt") {
                try downloadGamesList(location)
            }
            else {
                try downloadGame(location, named: fileName)
            }
        } catch {
            print ("file error: \(error)")
        }
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            os_log("Download error: %@", type: .error, String(describing: error))
        } else {
            os_log("Task finished: %@", type: .info, task)
        }
    }
}
