#pragma once
#include "foundation_json.h"

// Same explicit street-type/case/spacing rules as the Windows input matcher.
namespace mac_address_search {
struct Street { std::wstring type, name; };
inline Street street(std::string_view utf8) {
    const auto wide = mac_json::wide(utf8);
    std::wstring text;
    bool pending_space = false;
    for (wchar_t ch : wide) {
        if (ch == L' ' || ch == L'\t' || ch == 0xa0 || ch == 0x202f || (ch >= 0x2000 && ch <= 0x200a)) {
            pending_space = !text.empty(); continue;
        }
        if (pending_space) text += L' ';
        pending_space = false;
        if (ch >= L'A' && ch <= L'Z') ch += L'a' - L'A';
        if (ch >= L'А' && ch <= L'Я') ch += L'а' - L'А';
        if (ch == L'І') ch = L'і';
        if (ch == L'Ї') ch = L'ї';
        if (ch == L'Є') ch = L'є';
        if (ch == L'Ґ') ch = L'ґ';
        if (ch == 0x2019 || ch == 0x02bc) ch = L'\'';
        text += ch;
    }
    struct Prefix { const wchar_t *label, *type; };
    constexpr Prefix prefixes[] = {{L"вулиця",L"вул"},{L"вул",L"вул"},{L"проспект",L"просп"},{L"просп",L"просп"},
        {L"пр-т",L"просп"},{L"провулок",L"пров"},{L"пров",L"пров"},{L"площа",L"пл"},{L"пл",L"пл"},
        {L"бульвар",L"бул"},{L"бульв",L"бул"},{L"бул",L"бул"},{L"б-р",L"бул"},{L"узвіз",L"узвіз"},
        {L"набережна",L"наб"},{L"наб",L"наб"},{L"шосе",L"шосе"}};
    for (const auto& prefix : prefixes) {
        const std::wstring_view label{prefix.label};
        if (!text.starts_with(label) || text.size() == label.size()) continue;
        auto at = label.size();
        if (text[at] != L'.' && text[at] != L' ') continue;
        while (at < text.size() && (text[at] == L'.' || text[at] == L' ')) ++at;
        return {prefix.type, text.substr(at)};
    }
    return {{}, std::move(text)};
}
inline bool same_street(std::string_view a, std::string_view b) {
    const auto input = street(a), canonical = street(b);
    return !input.name.empty() && input.name == canonical.name && (input.type.empty() || input.type == canonical.type);
}
} // namespace mac_address_search
