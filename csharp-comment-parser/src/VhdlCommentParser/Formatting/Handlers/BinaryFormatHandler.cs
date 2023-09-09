using System.Text.RegularExpressions;
using VhdlCommentParser.Formatting;

namespace VhdlCommentParser;

internal partial record class BinaryFormatHandler(int Length) : IFormatHandler
{
    public static bool TryCreateFor(string format, out IFormatHandler? handler)
    {
        // F::base_2:<length>
        Match match = FormatRegex().Match(format);
        if (match.Success)
        {
            int length = Convert.ToInt32(match.Groups["length"].Value);
            handler = new BinaryFormatHandler(length);
            return true;
        }
        handler = null;
        return false;
    }

    public string Format(string cellValue) =>
        cellValue.Equals("X")
            ? new string('-', Length)
            : cellValue;

    [GeneratedRegex("F::base_2:(?<length>[0-9]+)")]
    private static partial Regex FormatRegex();
}
