// Nachgestelltes adb / curl / ssh für den Test der Batch-Dateien.
// Die EXE wird unter dem Namen des echten Programms kopiert (adb.exe, curl.exe, ssh.exe).
// Sie schreibt jeden Aufruf mit seinen Argumenten nach %DEP_FAKE_DIR%\aufrufe.log und
// antwortet nach den Regeln in %DEP_FAKE_DIR%\<name>.regeln:
//   "? text"   Regel passt, wenn die Argumente (mit Leerzeichen verbunden) "text" enthalten
//   "?1 text"  wie oben, gilt aber nur beim ersten Treffer (für Abläufe mit Zustandswechsel)
//   "#exit N"  Rückgabewert N
//   alles andere bis zur nächsten Regel ist die Ausgabe
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

public static class Fake
{
    static bool IsRule(string l) { return l.StartsWith("? ") || l.StartsWith("?1 "); }

    public static int Main(string[] args)
    {
        string dir = Environment.GetEnvironmentVariable("DEP_FAKE_DIR");
        string name = Path.GetFileNameWithoutExtension(System.Reflection.Assembly.GetExecutingAssembly().Location).ToLowerInvariant();
        string joined = string.Join(" ", args);
        var utf8 = new UTF8Encoding(false);
        File.AppendAllText(Path.Combine(dir, "aufrufe.log"), name + "\t" + string.Join("\t", args) + "\n", utf8);

        string rulesFile = Path.Combine(dir, name + ".regeln");
        if (!File.Exists(rulesFile)) return 0;
        string[] lines = File.ReadAllLines(rulesFile, Encoding.UTF8);
        string usedFile = Path.Combine(dir, name + ".benutzt");
        var used = new HashSet<string>(File.Exists(usedFile) ? File.ReadAllLines(usedFile) : new string[0]);

        for (int i = 0; i < lines.Length; i++)
        {
            if (!IsRule(lines[i])) continue;
            bool once = lines[i].StartsWith("?1 ");
            string pat = lines[i].Substring(once ? 3 : 2);
            if (joined.IndexOf(pat, StringComparison.Ordinal) < 0) continue;
            if (once)
            {
                if (used.Contains(i.ToString())) continue;
                File.AppendAllText(usedFile, i + "\n");
            }
            int code = 0;
            var sb = new StringBuilder();
            for (int j = i + 1; j < lines.Length && !IsRule(lines[j]); j++)
            {
                if (lines[j].StartsWith("#exit ")) { code = int.Parse(lines[j].Substring(6)); continue; }
                sb.Append(lines[j]).Append("\n");
            }
            byte[] bytes = utf8.GetBytes(sb.ToString());
            string outFile = null;
            if (name == "curl")
                for (int k = 0; k < args.Length - 1; k++) if (args[k] == "-o") outFile = args[k + 1];
            if (outFile != null) File.WriteAllBytes(outFile, bytes);
            else { Stream o = Console.OpenStandardOutput(); o.Write(bytes, 0, bytes.Length); o.Flush(); }
            return code;
        }
        return 0;
    }
}
