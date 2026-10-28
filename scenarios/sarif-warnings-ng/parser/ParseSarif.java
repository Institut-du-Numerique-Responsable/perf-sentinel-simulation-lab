import edu.hm.hafner.analysis.FileReaderFactory;
import edu.hm.hafner.analysis.Report;
import edu.hm.hafner.analysis.parser.violations.SarifAdapter;
import java.nio.file.Path;

/**
 * Parses a SARIF file the way the Warnings NG "sarif" tool does and prints one
 * tab-separated line per issue: rule, file, line. A file the parser rejects
 * throws a ParsingException, so the JVM exits non-zero.
 */
public class ParseSarif {
    public static void main(String[] args) {
        Report report = new SarifAdapter().parse(new FileReaderFactory(Path.of(args[0])));
        report.forEach(issue -> System.out.println(
                issue.getType() + "\t" + issue.getFileName() + "\t" + issue.getLineStart()));
    }
}
