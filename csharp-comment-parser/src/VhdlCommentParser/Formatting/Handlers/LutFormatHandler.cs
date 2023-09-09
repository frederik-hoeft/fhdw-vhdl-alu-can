using System.Text.Json;
using System.Text.RegularExpressions;
using VhdlCommentParser.Formatting;

namespace VhdlCommentParser;

internal partial record class LutFormatHandler(int Length, IReadOnlyDictionary<string, string> LookupTable) : IFormatHandler
{
    public static bool TryCreateFor(string format, out IFormatHandler? handler)
    {
        // F::lut:<length>-><filename>.json
        Match match = FormatRegex().Match(format);
        if (match.Success)
        {
            int length = Convert.ToInt32(match.Groups["length"].Value);
            string file = match.Groups["file"].Value;
            using Stream stream = File.OpenRead(file);
            Dictionary<string, string> lut = JsonSerializer.Deserialize<Dictionary<string, string>>(stream)
                ?? throw new FormatException("Unable to deserialize lookup table!");

            handler = new LutFormatHandler(length, lut);
            return true;
        }
        handler = null;
        return false;
    }

    public string Format(string cellValue) =>
        cellValue.Equals("X")
            ? new string('-', Length)
            : LookupTable[cellValue];

    [GeneratedRegex("F::lut:(?<length>[0-9]+)->(?<file>.+?\\.json)")]
    private static partial Regex FormatRegex();
}
