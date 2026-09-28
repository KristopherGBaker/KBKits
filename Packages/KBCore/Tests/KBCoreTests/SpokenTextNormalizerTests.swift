import Foundation
import Testing
@testable import KBCore

/// Ported from abogen's `test_text_normalization.py` and
/// `test_date_normalization_comprehensive.py`, adapted to this package's chosen year
/// convention ("nineteen ninety-five", not abogen's "nineteen hundred ninety").
@Suite("SpokenTextNormalizer")
struct SpokenTextNormalizerTests {

    private func normalize(_ text: String) -> String {
        SpokenTextNormalizer.normalize(text)
    }

    // MARK: Integer speller

    @Test func cardinalsSpellOut() {
        #expect(EnglishNumberWords.cardinal(0) == "zero")
        #expect(EnglishNumberWords.cardinal(42) == "forty-two")
        #expect(EnglishNumberWords.cardinal(100) == "one hundred")
        #expect(EnglishNumberWords.cardinal(105) == "one hundred five")
        #expect(EnglishNumberWords.cardinal(1204) == "one thousand two hundred four")
        #expect(EnglishNumberWords.cardinal(35000) == "thirty-five thousand")
        #expect(EnglishNumberWords.cardinal(-7) == "minus seven")
        #expect(EnglishNumberWords.cardinal(1_000_000) == "one million")
    }

    @Test func ordinalsSpellOut() {
        #expect(EnglishNumberWords.ordinal(1) == "first")
        #expect(EnglishNumberWords.ordinal(2) == "second")
        #expect(EnglishNumberWords.ordinal(15) == "fifteenth")
        #expect(EnglishNumberWords.ordinal(21) == "twenty-first")
        #expect(EnglishNumberWords.ordinal(20) == "twentieth")
        #expect(EnglishNumberWords.ordinal(100) == "one hundredth")
    }

    // MARK: Numbers

    @Test func groupedNumbersSpelledOut() {
        #expect(normalize("The vault holds 35,000 credits").lowercased().contains("thirty-five thousand"))
    }

    @Test func plainNumbersSpelledOut() {
        #expect(normalize("He rolled a 42.").lowercased().contains("forty-two"))
    }

    @Test func decimalsIncludePoint() {
        #expect(normalize("Book 4.5 of the series.").lowercased().contains("four point five"))
    }

    @Test func rangesUseTo() {
        #expect(normalize("Chapters 1-3").lowercased().contains("one to three"))
        #expect(normalize("ages 5–10").lowercased().contains("five to ten"))
    }

    @Test func spaceSeparatedRange() {
        #expect(normalize("Read pages 12 14 tonight.").lowercased().contains("twelve to fourteen"))
    }

    @Test func simpleFractions() {
        #expect(normalize("Add 1/2 cup of sugar").lowercased().contains("one half"))
        #expect(normalize("about 3/4 done").lowercased().contains("three quarters"))
        #expect(normalize("two thirds 2/3").lowercased().contains("two thirds"))
    }

    // MARK: Years

    @Test func yearsUseCommonPronunciation() {
        #expect(SpokenTextNormalizer.yearWords(1995) == "nineteen ninety-five")
        #expect(SpokenTextNormalizer.yearWords(1905) == "nineteen oh five")
        #expect(SpokenTextNormalizer.yearWords(2000) == "two thousand")
        #expect(SpokenTextNormalizer.yearWords(2009) == "two thousand nine")
        #expect(SpokenTextNormalizer.yearWords(2010) == "twenty ten")
        #expect(SpokenTextNormalizer.yearWords(1900) == "nineteen hundred")
    }

    @Test func recentYearTwentyStyle() {
        let folded = normalize("In 2025 we planned ahead").lowercased().replacingOccurrences(of: "-", with: " ")
        #expect(folded.contains("twenty twenty five"))
    }

    @Test func twoThousandsPrefix() {
        #expect(normalize("In 2005 we celebrated").lowercased().contains("two thousand five"))
    }

    @Test func addressNumbersAreNotYears() {
        let result = normalize("My address is 1925 Main St.").lowercased()
        #expect(!result.contains("nineteen twenty-five"))
        #expect(result.contains("one thousand"))
    }

    // MARK: Currency

    @Test func currencyMagnitudeAndPlain() {
        let cases: [(String, String)] = [
            ("$2 million", "two million dollars"),
            ("$2.5 million", "two point five million dollars"),
            ("$100 billion", "one hundred billion dollars"),
            ("$1 million", "one million dollars"),
            ("$100", "one hundred dollars"),
            ("$2.50", "two dollars, fifty cents")
        ]
        for (input, expected) in cases {
            let got = normalize(input).lowercased()
            #expect(got.contains(expected), "Failed for \(input): got '\(got)'")
        }
    }

    @Test func currencyUnderOneDollarUsesCents() {
        let folded = normalize("It cost $0.99.").lowercased()
        #expect(!folded.contains("zero dollars"))
        #expect(folded.contains("cents"))
    }

    // MARK: Titles & suffixes

    @Test func titleAbbreviationsExpand() {
        let result = normalize("Dr. Watson met Mr. Holmes and Ms. Hudson.")
        #expect(result.contains("Doctor"))
        #expect(result.contains("Mister"))
        #expect(result.contains("Miz"))
    }

    @Test func suffixAbbreviationsPreserveCase() {
        let result = normalize("John Doe Jr. spoke to JANE DOE SR. about the estate.")
        #expect(result.contains("Junior"))
        #expect(result.uppercased().contains("SENIOR"))
    }

    @Test func saintVsStreet() {
        #expect(normalize("St. Peter walked.").contains("Saint Peter"))
        #expect(normalize("Turn onto Main St.").contains("Main Street"))
    }

    // MARK: Roman numerals

    @Test func romanNumeralsInTitles() {
        #expect(normalize("Chapter IV begins now").lowercased().contains("chapter four"))
        #expect(normalize("We studied part iii of the manuscript.").lowercased().contains("part three"))
        #expect(normalize("They executed phase-IV without delay.").lowercased().contains("phase four"))
    }

    @Test func romanSuffixOrdinals() {
        #expect(normalize("Bob Smith II arrived late").lowercased().contains("bob smith the second"))
    }

    @Test func pronounIIsNotMangled() {
        let result = normalize("I think I can.")
        #expect(result.contains("I think I can"))
    }

    @Test func romanToIntRejectsMalformed() {
        #expect(SpokenTextNormalizer.romanToInt("IV") == 4)
        #expect(SpokenTextNormalizer.romanToInt("IIII") == nil)
        #expect(SpokenTextNormalizer.romanToInt("hello") == nil)
    }

    // MARK: Acronyms, caps, footnotes

    @Test func dottedAcronymsLoseDots() {
        let result = normalize("Meet near the U.S.A. border.")
        #expect(!result.lowercased().contains(" dot "))
        #expect(result.contains("USA"))
    }

    @Test func allCapsAreSentenceCased() {
        let result = normalize("\"THIS IS A TEST.\"")
        #expect(result.contains("This is a test"))
    }

    @Test func capsPreservesAcronyms() {
        let result = normalize("THE NASA TEAM ARRIVED.")
        #expect(result.contains("NASA"))
        #expect(result.contains("The"))
    }

    @Test func bracketFootnotesStripped() {
        let result = normalize("The claim[12] was bold")
        #expect(!result.contains("[12]"))
        #expect(result.contains("claim"))
    }

    // MARK: Terminal punctuation

    @Test func missingTerminalPunctuationAdded() {
        #expect(normalize("Chapter 1").hasSuffix("."))
    }

    @Test func terminalRespectsClosingQuotes() {
        let result = normalize("\"Chapter one\"")
        #expect(result.replacingOccurrences(of: " ", with: "").hasSuffix(".\""))
    }

    @Test func existingTerminalUntouched() {
        #expect(normalize("Done.") == "Done.")
        #expect(normalize("Really?") == "Really?")
    }

    // MARK: Options gating

    @Test func numbersCanBeDisabled() {
        var options = SpokenTextNormalizer.Options.default
        options.numbers = false
        #expect(SpokenTextNormalizer.normalize("He rolled a 42.", options: options).contains("42"))
    }

    @Test func yearStyleCanBeDisabled() {
        var options = SpokenTextNormalizer.Options.default
        options.yearStyle = false
        let folded = SpokenTextNormalizer.normalize("In 2025 we planned", options: options)
            .lowercased().replacingOccurrences(of: "-", with: " ")
        #expect(!folded.contains("twenty twenty five"))
    }
}
