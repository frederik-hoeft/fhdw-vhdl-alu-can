using System.Text.RegularExpressions;
using VhdlCommentParser.Formatting;

namespace VhdlCommentParser;

internal partial record class DecimalFormatHandler(int Length, uint Mask) : IFormatHandler
{
    public static bool TryCreateFor(string format, out IFormatHandler? handler)
    {
        // FORMAT::base_10:<length>
        Match match = FormatRegex().Match(format);
        if (match.Success)
        {
            int length = Convert.ToInt32(match.Groups["length"].Value);
            uint mask = (1u << length) - 1;
            handler = new DecimalFormatHandler(length, mask);
            return true;
        }
        handler = null;
        return false;
    }

    public string Format(string cellValue) => 
        cellValue.Equals("X") 
            ? new string('-', Length) 
            : Convert.ToString(((uint)Convert.ToInt32(cellValue)) & Mask, 2).PadLeft(Length, '0');

    [GeneratedRegex("F::base_10:(?<length>[0-9]+)")]
    private static partial Regex FormatRegex();
}
