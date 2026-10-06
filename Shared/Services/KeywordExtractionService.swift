import Foundation
import NaturalLanguage

class KeywordExtractionService {
    func extractKeywords(from text: String, maxKeywords: Int = 20) -> [String] {
        var keywords: [String] = []
        
        let frequencyResults = extractUsingFrequency(from: text, maxKeywords: maxKeywords * 2)
        keywords.append(contentsOf: frequencyResults)
        
        let deduplicated = Array(Set(keywords))
            .filter { $0.count >= 2 }
            .sorted { ($0.count) > ($1.count) }
        
        return Array(deduplicated.prefix(maxKeywords))
    }
    
    private func extractUsingFrequency(from text: String, maxKeywords: Int) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text
        
        var wordCounts: [String: Int] = [:]
        var totalWords = 0
        
        let stopWords = Set([
            "的", "是", "在", "了", "和", "与", "或", "等", "这", "那",
            "the", "is", "are", "was", "were", "be", "been", "being",
            "have", "has", "had", "do", "does", "did", "will", "would",
            "could", "should", "may", "might", "must", "shall", "can",
            "a", "an", "the", "and", "or", "but", "if", "then", "else",
            "for", "of", "to", "in", "on", "at", "by", "with", "from",
            "as", "into", "through", "during", "before", "after", "above",
            "below", "between", "under", "again", "further", "then", "once"
        ])
        
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitPunctuation, .omitWhitespace]
        ) { tag, tokenRange in
            guard let tag = tag else { return true }
            
            if tag == .noun || tag == .verb {
                let word = String(text[tokenRange]).lowercased()
                if word.count >= 2 && !stopWords.contains(word.lowercased()) {
                    wordCounts[word, default: 0] += 1
                    totalWords += 1
                }
            }
            return true
        }
        
        let sortedWords = wordCounts
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(maxKeywords)
            .map { $0.key }
        
        return Array(sortedWords)
    }
    
    func extractKeySentences(from text: String, maxSentences: Int = 10) -> [String] {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: "。！？\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 10 }
        
        var sentenceScores: [(String, Int)] = []
        
        for sentence in sentences {
            var score = 0
            
            if sentence.contains("必须") || sentence.contains("重点") || sentence.contains("关键") ||
               sentence.contains("important") || sentence.contains("key") || sentence.contains("must") {
                score += 3
            }
            
            if sentence.contains("概念") || sentence.contains("定义") || sentence.contains("原理") ||
               sentence.contains("definition") || sentence.contains("concept") || sentence.contains("principle") {
                score += 2
            }
            
            if sentence.contains("例") || sentence.contains("例如") || sentence.contains("example") {
                score += 1
            }
            
            score += sentence.filter { $0 == "，" || $0 == "、" }.count / 2
            
            sentenceScores.append((sentence, score))
        }
        
        let sortedSentences = sentenceScores
            .sorted { $0.1 > $1.1 }
            .prefix(maxSentences)
            .map { $0.0 }
        
        return Array(sortedSentences)
    }
    
    func analyzeTextDifficulty(text: String) -> TextDifficulty {
        let wordCount = text.components(separatedBy: .whitespaces).count
        let sentenceCount = text.components(separatedBy: CharacterSet(charactersIn: "。！？")).count
        
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        
        var complexWordCount = 0
        
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitPunctuation, .omitWhitespace]
        ) { tag, tokenRange in
            if let tag = tag, tag == .adjective || tag == .adverb {
                complexWordCount += 1
            }
            return true
        }
        
        let averageWordsPerSentence = sentenceCount > 0 ? Double(wordCount) / Double(sentenceCount) : 0
        let complexRatio = wordCount > 0 ? Double(complexWordCount) / Double(wordCount) : 0
        
        if averageWordsPerSentence > 25 || complexRatio > 0.3 {
            return .hard
        } else if averageWordsPerSentence > 15 || complexRatio > 0.15 {
            return .medium
        } else {
            return .easy
        }
    }
}

enum TextDifficulty: String {
    case easy = "简单"
    case medium = "中等"
    case hard = "困难"
    
    var color: String {
        switch self {
        case .easy: return "green"
        case .medium: return "orange"
        case .hard: return "red"
        }
    }
}
