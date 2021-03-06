//
//  CMLogProcessor.swift
//  BuildTimeAnalyzer
//
//  Created by Robert Gummesson on 01/05/2016.
//  Copyright © 2016 Robert Gummesson. All rights reserved.
//

typealias CMUpdateClosure = (result: [CMCompileMeasure], didComplete: Bool) -> ()

protocol CMLogProcessorProtocol: class {
    var unprocessedResult: [CMRawMeasure] { get set }
    var updateHandler: CMUpdateClosure? { get set }
    var workspace: CMXcodeWorkSpace? { get set }
    var shouldCancel: Bool { get set }
    
    func processingDidStart()
    func processingDidFinish()
}

private let processRx = try! NSRegularExpression(pattern:  "^\\d*\\.?\\dms\\t/", options: [])

extension CMLogProcessorProtocol {
    func process(productName: String, buildCompletionDate: NSDate?, updateHandler: CMUpdateClosure?) {
        workspace = CMXcodeWorkSpace(productName: productName, buildCompletionDate: buildCompletionDate)
        workspace?.logTextForProduct() { [weak self] (text) in
            guard let text = text else {
                updateHandler?(result: [], didComplete: true)
                return
            }
            
            self?.updateHandler = updateHandler
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)) {
                self?.process(text: text)
            }
        }
    }
    
    // MARK: Private methods
    
    private func process(text text: String) {
        let characterSet = NSCharacterSet(charactersInString:"\r\"")
        var remainingRange = text.startIndex..<text.endIndex
        var rawMeasures: [String:Double] = [:]

        unprocessedResult.removeAll()
        processingDidStart()
        
        while let nextRange = text.rangeOfCharacterFromSet(characterSet, options: [], range: remainingRange) {
            let currentRange = remainingRange.startIndex..<nextRange.endIndex
            let text = text.substringWithRange(currentRange)
            
            defer {
                remainingRange = nextRange.endIndex..<remainingRange.endIndex
            }
            
            let range = NSMakeRange(0, text.characters.count)
            guard let match = processRx.firstMatchInString(text, options: [], range: range) else { continue }
            
            let timeString = text.substringToIndex(text.startIndex.advancedBy(match.range.length - 4))
            if let time = Double(timeString) {
                let value = text.substringFromIndex(text.startIndex.advancedBy(match.range.length - 1))

                let cumulativeTime = rawMeasures[value] ?? 0
                rawMeasures[value] = cumulativeTime + time
            }
            if shouldCancel {
                break
            }
        }

        for (k, v) in rawMeasures {
            // Only show files whose compile time is above 10ms
            if v > 10 {
                unprocessedResult.append(CMRawMeasure(time: v, text: k))
            }
        }

        processingDidFinish()
    }
    
    private func updateResults(didComplete: Bool) {
        var results = processResult(unprocessedResult)
        results = groupResultsBySourceLine(results)
        results.sortInPlace{ $0.time > $1.time }

        updateHandler?(result: results, didComplete: didComplete)
        if didComplete {
            unprocessedResult.removeAll()
        }
    }

    private func processResult(unprocessedResult: [CMRawMeasure]) -> [CMCompileMeasure] {
        var result: [CMCompileMeasure] = []
        for entry in unprocessedResult {
            let code = entry.text.characters.split("\t").map(String.init)
            if code.count >= 2, let measure = CMCompileMeasure(time: entry.time, rawPath: code[0], code: trimPrefixes(code[1])) {
                result.append(measure)
            }
        }
        return result
    }

    private func groupResultsBySourceLine(results: [CMCompileMeasure]) -> [CMCompileMeasure] {
        var grouped: [String:CMCompileMeasure] = [:]
        for result in results {
            let key = result.fileAndLine
            if var measure = grouped[key] {
                measure.time += result.time
                grouped[key] = measure
            } else {
                grouped[key] = result
            }
        }
        return Array(grouped.values)
    }
    
    private func trimPrefixes(code: String) -> String {
        var code = code
        ["@objc ", "final ", "@IBAction "].forEach { (prefix) in
            if code.hasPrefix(prefix) {
                code = code.substringFromIndex(code.startIndex.advancedBy(prefix.characters.count))
            }
        }
        return code
    }
}

class CMLogProcessor: NSObject, CMLogProcessorProtocol {
    
    var unprocessedResult: [CMRawMeasure] = []
    var updateHandler: CMUpdateClosure?
    var workspace: CMXcodeWorkSpace?
    var shouldCancel = false
    var timer: NSTimer?
    
    func processingDidStart() {
        dispatch_async(dispatch_get_main_queue()) {
            self.timer = NSTimer.scheduledTimerWithTimeInterval(1, target: self, selector: #selector(self.timerCallback(_:)), userInfo: nil, repeats: true)
        }
    }
    
    func processingDidFinish() {
        dispatch_async(dispatch_get_main_queue()) {
            self.timer?.invalidate()
            self.timer = nil
            self.shouldCancel = false
            self.updateResults(true)
        }
    }
    
    func timerCallback(timer: NSTimer) {
        updateResults(false)
    }
}