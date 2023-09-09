using System.Globalization;
using System.Text.RegularExpressions;
using VhdlCommentParser.Formatting;

namespace VhdlCommentParser;

internal partial record class HexFormatHandler(int Length) : IFormatHandler
{
    public static bool TryCreateFor(string format, out IFormatHandler? handler)
    {
        // F::base_16:<length>
        Match match = FormatRegex().Match(format);
        if (match.Success)
        {
            int length = Convert.ToInt32(match.Groups["length"].Value);
            handler = new HexFormatHandler(length);
            return true;
        }
        handler = null;
        return false;
    }

    public string Format(string cellValue) => 
        cellValue.Equals("X")
            ? new string('-', Length) 
            : Convert.ToString(int.Parse(cellValue, NumberStyles.HexNumber), 2).PadLeft(Length, '0');

    [GeneratedRegex("F::base_16:(?<length>[0-9]+)")]
    private static partial Regex FormatRegex();
}
