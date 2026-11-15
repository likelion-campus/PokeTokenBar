import Foundation

/// The texts `Tests/PlazaParityGoldens/breaks.json` was measured on: what the plaza wraps (names, chat, panel text) and
/// what breaks line-breaking rules (long Korean words, URLs, emoji sequences, right-to-left, runs of spaces, hard
/// newlines). Not modelled, so not in the corpus: tabs (TextKit expands them to tab stops), no-break spaces and a ZWJ
/// between letters (TextKit measures both differently from CoreText's glyph advances). The Mac measures TextKit and CTFramesetter on them; both OSes run the golden clusters through
/// `PlazaLineBreaker`. Adding a text means regenerating the golden (`PTB_PLAZA_GOLDENS_WRITE=1`).
enum PlazaBreakCorpus {
    static let widths: [CGFloat] = [40, 80, 120, 200, 340]

    static let texts: [String] = [
        // short Korean and Latin
        "", "나", "안녕", "안녕하세요", "Hello", "Hi there", "a", " ", "  ", "ok.",
        // Korean sentences
        "안녕하세요 오늘 광장에서 만나요", "배고프다 점심 뭐 먹지", "오늘도 토큰을 많이 썼어요 정말로요",
        "이 포켓몬은 불꽃 타입이라서 물 근처에서는 조심해야 해요", "광장에 눈이 내리고 있어요, 모닥불 옆에 모여요!",
        "가나다라마바사아자차카타파하 가나다라마바사아자차카타파하", "대한민국만세 대한민국만세 대한민국만세",
        "토큰을아주많이사용했어요오늘은쉬어야겠습니다", "한 두 세 네 다섯 여섯 일곱 여덟 아홉 열",
        "이것은 매우 긴 단어입니다: 가나다라마바사아자차카타파하거너더러머버서어저처커터퍼허",
        "안녕\n두 번째 줄\n\n네 번째 줄", "끝에 공백이 있어요   ", "   앞에 공백이 있어요", "공백이    여러    개    있어요",
        "ㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋ", "ㅎㅎ 웃겨 ㅋㅋㅋ 진짜 ㅠㅠ", "(괄호) 안의 말, 쉼표와 마침표. 그리고 느낌표!",
        "“따옴표” 안의 ‘작은’ 따옴표 «프랑스식»", "1234567890 1234567890 1234567890", "3.14159265358979 와 2.71828182845904",
        "가격은 1,234,567원이고 할인율은 15.5%입니다", "한글과English가섞인문장mixedTextWithoutSpaces입니다",
        // Latin
        "The quick brown fox jumps over the lazy dog", "Pneumonoultramicroscopicsilicovolcanoconiosis",
        "A short one", "word  with   runs    of     spaces", "trailing spaces   ", "hyphen-ated well-known state-of-the-art words",
        "em—dash and en–dash and ellipsis… done", "naïve café résumé coöperate Zürich", "ALL CAPS SHOUTING TEXT HERE OK",
        "line one\nline two\r\nline three\rline four",
        "Mixed 한글 and English 문장 together in one line of text", "Pikachu used Thunderbolt! It's super effective!!",
        // URLs, paths, code-ish
        "https://github.com/likelion-campus/PokeTokenBar/releases/latest", "see https://example.com/a/b?c=d&e=f now",
        "C:\\Users\\name\\AppData\\Local\\PokeTokenBar\\logs", "/usr/local/bin/poketokenbar --verbose --team=ABC",
        "user@example.com wrote: ok", "snake_case_identifier_that_is_quite_long and camelCaseIdentifierThatIsLong",
        // punctuation and brackets
        "((( nested [brackets] {and} <angles> )))", "!!!??? ...!!! ,,, ;;; ::: ---", "no break after open ( paren or before close ) paren",
        "\"quoted text\" and 'single' and `code`", "100% sure; 50/50 chance; a+b=c; x*y/z", "price: $1,000.00 – €900 – ¥100,000",
        // emoji and sequences
        "🔥", "🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥", "불꽃 🔥 물 💧 풀 🌿", "👍🏽 skin tone 👍🏿 modifiers 👍🏻 here", "👨‍👩‍👧‍👦 family 👩‍💻 technologist 🏳️‍🌈 flag",
        "🇰🇷 🇺🇸 🇯🇵 flags 🇫🇷🇩🇪🇮🇹 side by side", "1️⃣2️⃣3️⃣ keycaps and ©️ ®️ ™️", "text then emoji🔥and more text🔥end", "❤️🧡💛💚💙💜🖤🤍🤎💔",
        // ZWJ, combining, controls
        "e\u{0301}le\u{0301}ve\u{0301} combining accents", "zero\u{200B}width\u{200B}space\u{200B}breaks here", "soft\u{00AD}hyphen\u{00AD}ation example word", "word\u{2060}joiner\u{2060}test",
        // right-to-left and other scripts
        "שלום עולם זה טקסט בעברית", "مرحبا بالعالم هذا نص عربي طويل", "Hello שלום world עולם mixed", "مرحبا Hello 안녕 مختلط",
        "こんにちは世界、これは日本語のテキストです。", "你好世界，这是一段中文文本。它没有空格。", "ภาษาไทยไม่มีช่องว่างระหว่างคำ",
        "Привет мир это русский текст", "Ελληνικά κείμενο με πολλές λέξεις", "हिन्दी पाठ में कई शब्द हैं",
    ]
}
