using System.Globalization;
using System.Text.RegularExpressions;
using VhdlCommentParser.Formatting;

namespace VhdlCommentParser;

internal partial record class PrefixFormatHandler(int Length, uint Mask) : IFormatHandler
{
    public static bool TryCreateFor(string format, out IFormatHandler? handler)
    {
        // F::prefix:<length>
        Match match = FormatRegex().Match(format);
        if (match.Success)
        {
            int length = Convert.ToInt32(match.Groups["length"].Value);
            uint mask = (1u << length) - 1;
            handler = new PrefixFormatHandler(length, mask);
            return true;
        }
        handler = null;
        return false;
    }

    public string Format(string cellValue) => cellValue switch
    {
        "X" => new string('-', Length),
        ['0', 'x', ..] => Convert.ToString(int.Parse(cellValue[2..], NumberStyles.HexNumber), 2).PadLeft(Length, '0'),
        ['0', 'b', ..] => cellValue[2..].PadLeft(Length, '0'),
        _ => Convert.ToString(((uint)Convert.ToInt32(cellValue)) & Mask, 2).PadLeft(Length, '0')
    };

    [GeneratedRegex("F::prefix:(?<length>[0-9]+)")]
    private static partial Regex FormatRegex();
}
