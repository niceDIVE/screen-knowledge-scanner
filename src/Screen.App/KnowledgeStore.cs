using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace Screen.App;

public sealed partial class KnowledgeStore
{
    public const string DatabaseFileName = "knowledge.db";
    public string DirectoryPath { get; }
    private readonly string connectionString;
    public KnowledgeStore(string directory)
    {
        DirectoryPath = Path.GetFullPath(directory);
        Directory.CreateDirectory(Path.Combine(DirectoryPath, "images"));
        connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = Path.Combine(DirectoryPath, DatabaseFileName),
            ForeignKeys = true,
            DefaultTimeout = 30
        }.ToString();
    }

    private SqliteConnection Open()
    {
        var c = new SqliteConnection(connectionString); c.Open(); return c;
    }
    private static string Now() => DateTimeOffset.UtcNow.ToString("O");
    private static string Id() => Guid.NewGuid().ToString("N");
    private static SqliteCommand Command(SqliteConnection c, string sql, params (string, object?)[] parameters)
    {
        var cmd = c.CreateCommand(); cmd.CommandText = sql;
        foreach (var (key, value) in parameters) cmd.Parameters.AddWithValue(key, value ?? DBNull.Value);
        return cmd;
    }

    public void Initialize()
    {
        using var c = Open();
        using var cmd = Command(c, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS runs (
              id TEXT PRIMARY KEY, title TEXT NOT NULL, created_at TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'open');
            CREATE TABLE IF NOT EXISTS frames (
              id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id), sequence INTEGER NOT NULL,
              captured_at TEXT NOT NULL, source TEXT NOT NULL, sha256 TEXT NOT NULL, image_type TEXT NOT NULL,
              width INTEGER NOT NULL, height INTEGER NOT NULL, region TEXT,
              ocr_state TEXT NOT NULL, ocr_text TEXT NOT NULL DEFAULT '', ocr_engine TEXT NOT NULL DEFAULT '', error TEXT,
              UNIQUE(run_id, sequence));
            CREATE TABLE IF NOT EXISTS jobs (
              id TEXT PRIMARY KEY, frame_id TEXT NOT NULL REFERENCES frames(id), state TEXT NOT NULL,
              attempts INTEGER NOT NULL DEFAULT 0, error TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS ix_jobs_state ON jobs(state, created_at);
            CREATE TABLE IF NOT EXISTS ocr_results (
              id INTEGER PRIMARY KEY, frame_id TEXT NOT NULL REFERENCES frames(id), text TEXT NOT NULL,
              engine TEXT NOT NULL, created_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS run_notes (id INTEGER PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id), message TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(frame_id UNINDEXED, tokens);
            PRAGMA user_version=1;
            """);
        cmd.ExecuteNonQuery();
        // A process restart retries interrupted work; completed and failed jobs retain their outcome.
        using var recover = Command(c, """
            UPDATE frames SET ocr_state='pending' WHERE id IN (SELECT frame_id FROM jobs WHERE state='processing');
            UPDATE jobs SET state='pending', updated_at=$now WHERE state='processing';
            """, ("$now", Now()));
        recover.ExecuteNonQuery();
    }

    public ScanRun CreateRun(string title)
    {
        var run = new ScanRun(Id(), string.IsNullOrWhiteSpace(title) ? "未命名采集" : title.Trim(), Now(), "open", 0);
        using var c = Open();
        using var cmd = Command(c, "INSERT INTO runs(id,title,created_at) VALUES($id,$title,$now)",
            ("$id", run.Id), ("$title", run.Title), ("$now", run.CreatedAt));
        cmd.ExecuteNonQuery(); return run;
    }

    public IReadOnlyList<ScanRun> Runs()
    {
        using var c = Open(); using var cmd = Command(c, """
            SELECT r.id,r.title,r.created_at,r.state,count(f.id) FROM runs r
            LEFT JOIN frames f ON f.run_id=r.id GROUP BY r.id ORDER BY r.created_at DESC
            """);
        using var r = cmd.ExecuteReader(); var list = new List<ScanRun>();
        while (r.Read()) list.Add(new(r.GetString(0), r.GetString(1), r.GetString(2), r.GetString(3), r.GetInt32(4)));
        return list;
    }
    public ScanRun? Run(string id) => Runs().FirstOrDefault(r => r.Id == id);
    public void FinishRun(string id)
    {
        using var c = Open(); using var cmd = Command(c, "UPDATE runs SET state='closed' WHERE id=$id", ("$id", id));
        cmd.ExecuteNonQuery();
    }
    public void AddNote(string runId, string message)
    {
        using var c = Open(); using var cmd = Command(c, "INSERT INTO run_notes(run_id,message) VALUES($run,$message)", ("$run", runId), ("$message", message));
        cmd.ExecuteNonQuery();
    }
    public IReadOnlyList<string> Notes(string runId)
    {
        using var c = Open(); using var cmd = Command(c, "SELECT message FROM run_notes WHERE run_id=$run ORDER BY id", ("$run", runId));
        using var r = cmd.ExecuteReader(); var notes = new List<string>(); while (r.Read()) notes.Add(r.GetString(0)); return notes;
    }
    public Region? GetRegion()
    {
        using var c = Open(); using var cmd = Command(c, "SELECT value FROM settings WHERE key='region'");
        return cmd.ExecuteScalar() is string value ? JsonSerializer.Deserialize<Region>(value) : null;
    }
    public void SetRegion(Region? region)
    {
        using var c = Open(); using var cmd = Command(c, "INSERT OR REPLACE INTO settings VALUES('region',$value)", ("$value", JsonSerializer.Serialize(region)));
        cmd.ExecuteNonQuery();
    }

    public Frame AddFrame(string runId, byte[] image, string source, Region? region = null, string? text = null)
    {
        var info = ImageInfo.Read(image);
        var hash = Convert.ToHexStringLower(SHA256.HashData(image));
        // Image bytes are committed before the record or OCR job becomes visible.
        var path = ImagePath(hash);
        if (!File.Exists(path))
        {
            var temporary = path + "." + Id() + ".tmp";
            File.WriteAllBytes(temporary, image);
            try { File.Move(temporary, path, false); }
            catch (IOException) when (File.Exists(path)) { File.Delete(temporary); }
        }
        using var c = Open(); using var tx = c.BeginTransaction();
        using var check = Command(c, "SELECT state FROM runs WHERE id=$id", ("$id", runId));
        if (check.ExecuteScalar() is not string state) throw new KeyNotFoundException("采集批次不存在。");
        if (state != "open") throw new InvalidOperationException("批次已结束，请创建新批次。");
        using var seq = Command(c, "SELECT coalesce(max(sequence),0)+1 FROM frames WHERE run_id=$run", ("$run", runId));
        var frame = new Frame(Id(), runId, Convert.ToInt32(seq.ExecuteScalar()), Now(), source, hash,
            info.Type, info.Width, info.Height, region, text is null ? "pending" : "succeeded", text ?? "", text is null ? "" : "manual", null);
        using var add = Command(c, """
            INSERT INTO frames VALUES($id,$run,$seq,$now,$source,$sha,$type,$w,$h,$region,$state,$text,$engine,NULL)
            """, ("$id", frame.Id), ("$run", runId), ("$seq", frame.Sequence), ("$now", frame.CapturedAt), ("$source", source),
            ("$sha", hash), ("$type", info.Type), ("$w", info.Width), ("$h", info.Height),
            ("$region", region is null ? null : JsonSerializer.Serialize(region)), ("$state", frame.OcrState),
            ("$text", frame.OcrText), ("$engine", frame.OcrEngine));
        add.ExecuteNonQuery();
        if (text is null) InsertJob(c, frame.Id);
        else SaveText(c, frame.Id, text, "manual");
        tx.Commit(); return frame;
    }

    public string ImagePath(string hash)
    {
        if (hash.Length != 64 || !hash.All(Uri.IsHexDigit))
            throw new ArgumentException("无效的原图 SHA-256。", nameof(hash));
        return Path.Combine(DirectoryPath, "images", hash);
    }
    private static Frame ReadFrame(SqliteDataReader r) => new(r.GetString(0), r.GetString(1), r.GetInt32(2),
        r.GetString(3), r.GetString(4), r.GetString(5), r.GetString(6), r.GetInt32(7), r.GetInt32(8),
        r.IsDBNull(9) ? null : JsonSerializer.Deserialize<Region>(r.GetString(9)), r.GetString(10), r.GetString(11),
        r.GetString(12), r.IsDBNull(13) ? null : r.GetString(13));
    public IReadOnlyList<Frame> Frames(string runId)
    {
        using var c = Open(); using var cmd = Command(c, "SELECT * FROM frames WHERE run_id=$run ORDER BY sequence", ("$run", runId));
        using var r = cmd.ExecuteReader(); var list = new List<Frame>();
        while (r.Read()) list.Add(ReadFrame(r)); return list;
    }
    public Frame? FrameById(string id)
    {
        using var c = Open(); using var cmd = Command(c, "SELECT * FROM frames WHERE id=$id", ("$id", id));
        using var r = cmd.ExecuteReader(); return r.Read() ? ReadFrame(r) : null;
    }
    public object Stats()
    {
        using var c = Open();
        long Count(string sql) { using var cmd = Command(c, sql); return Convert.ToInt64(cmd.ExecuteScalar()); }
        return new
        {
            runs = Count("SELECT count(*) FROM runs"),
            frames = Count("SELECT count(*) FROM frames"),
            pending = Count("SELECT count(*) FROM jobs WHERE state IN ('pending','processing')"),
            failed = Count("SELECT count(*) FROM jobs WHERE state='failed'"),
            recognized = Count("SELECT count(*) FROM frames WHERE ocr_state='succeeded'")
        };
    }

    private static string InsertJob(SqliteConnection c, string frameId)
    {
        var id = Id();
        using var cmd = Command(c, "INSERT INTO jobs VALUES($id,$frame,'pending',0,NULL,$now,$now)",
            ("$id", id), ("$frame", frameId), ("$now", Now())); cmd.ExecuteNonQuery(); return id;
    }
    public string Retry(string frameId)
    {
        using var c = Open(); using var tx = c.BeginTransaction();
        using var exists = Command(c, "SELECT id FROM frames WHERE id=$id", ("$id", frameId));
        if (exists.ExecuteScalar() is null) throw new KeyNotFoundException("截图不存在。");
        using var active = Command(c, "SELECT id FROM jobs WHERE frame_id=$id AND state IN ('pending','processing')", ("$id", frameId));
        var id = active.ExecuteScalar() as string;
        if (id is null)
        {
            id = InsertJob(c, frameId);
            using var update = Command(c, "UPDATE frames SET ocr_state='pending',error=NULL WHERE id=$id", ("$id", frameId));
            update.ExecuteNonQuery();
        }
        tx.Commit(); return id;
    }
    private static Job ReadJob(SqliteDataReader r) => new(r.GetString(0), r.GetString(1), r.GetString(2),
        r.GetInt32(3), r.IsDBNull(4) ? null : r.GetString(4), r.GetString(5), r.GetString(6));
    public IReadOnlyList<Job> Jobs()
    {
        using var c = Open(); using var cmd = Command(c, "SELECT * FROM jobs ORDER BY created_at DESC LIMIT 100");
        using var r = cmd.ExecuteReader(); var list = new List<Job>(); while (r.Read()) list.Add(ReadJob(r)); return list;
    }
    public Job? ClaimJob()
    {
        using var c = Open(); using var tx = c.BeginTransaction(); Job? job;
        using (var cmd = Command(c, "SELECT * FROM jobs WHERE state='pending' ORDER BY created_at LIMIT 1"))
        using (var r = cmd.ExecuteReader()) job = r.Read() ? ReadJob(r) : null;
        if (job is null) { tx.Commit(); return null; }
        using var claim = Command(c, """
            UPDATE jobs SET state='processing',attempts=attempts+1,updated_at=$now WHERE id=$id;
            UPDATE frames SET ocr_state='processing' WHERE id=$frame;
            """, ("$now", Now()), ("$id", job.Id), ("$frame", job.FrameId));
        claim.ExecuteNonQuery(); tx.Commit(); return job with { State = "processing", Attempts = job.Attempts + 1 };
    }
    private static void SaveText(SqliteConnection c, string frameId, string text, string engine)
    {
        using var cmd = Command(c, """
            INSERT INTO ocr_results(frame_id,text,engine,created_at) VALUES($id,$text,$engine,$now);
            UPDATE frames SET ocr_text=$text,ocr_engine=$engine,ocr_state='succeeded',error=NULL WHERE id=$id;
            DELETE FROM search WHERE frame_id=$id;
            INSERT INTO search(frame_id,tokens) VALUES($id,$tokens);
            """, ("$id", frameId), ("$text", text), ("$engine", engine), ("$now", Now()), ("$tokens", string.Join(' ', Tokens(text))));
        cmd.ExecuteNonQuery();
    }
    public void CorrectText(string frameId, string text)
    {
        using var c = Open(); using var tx = c.BeginTransaction();
        using var check = Command(c, "SELECT id FROM frames WHERE id=$id", ("$id", frameId));
        if (check.ExecuteScalar() is null) throw new KeyNotFoundException("截图不存在。");
        using var busy = Command(c, "SELECT count(*) FROM jobs WHERE frame_id=$id AND state IN ('pending','processing')", ("$id", frameId));
        if (Convert.ToInt32(busy.ExecuteScalar()) > 0) throw new InvalidOperationException("识别正在进行，请完成后再校对。");
        SaveText(c, frameId, text, "manual"); tx.Commit();
    }
    public object[] Revisions(string frameId)
    {
        using var c = Open(); using var cmd = Command(c, "SELECT text,engine,created_at FROM ocr_results WHERE frame_id=$id ORDER BY id DESC", ("$id", frameId));
        using var r = cmd.ExecuteReader(); var list = new List<object>();
        while (r.Read()) list.Add(new { text = r.GetString(0), engine = r.GetString(1), createdAt = r.GetString(2) }); return list.ToArray();
    }
    public void Complete(Job job, OcrResult result)
    {
        using var c = Open(); using var tx = c.BeginTransaction(); SaveText(c, job.FrameId, result.Text, result.Engine);
        using var cmd = Command(c, "UPDATE jobs SET state='succeeded',error=NULL,updated_at=$now WHERE id=$id", ("$now", Now()), ("$id", job.Id));
        cmd.ExecuteNonQuery(); tx.Commit();
    }
    public void Fail(Job job, string message)
    {
        using var c = Open(); using var tx = c.BeginTransaction();
        using var cmd = Command(c, """
            UPDATE jobs SET state='failed',error=$error,updated_at=$now WHERE id=$id;
            UPDATE frames SET ocr_state='failed',error=$error WHERE id=$frame;
            """, ("$error", message), ("$now", Now()), ("$id", job.Id), ("$frame", job.FrameId));
        cmd.ExecuteNonQuery(); tx.Commit();
    }

    [GeneratedRegex(@"[\u3400-\u9fff]+|[a-z0-9]+", RegexOptions.IgnoreCase)] private static partial Regex Words();
    public static IEnumerable<string> Tokens(string text)
    {
        foreach (Match match in Words().Matches(text.Normalize(NormalizationForm.FormKC).ToLowerInvariant()))
        {
            var word = match.Value;
            if (word[0] is >= '\u3400' and <= '\u9fff' && word.Length > 1)
                for (var i = 0; i < word.Length - 1; i++) yield return word.Substring(i, 2);
            else yield return word;
        }
    }
    public IReadOnlyList<SearchHit> Search(string query)
    {
        var tokens = Tokens(query).Distinct().ToArray(); if (tokens.Length == 0) return [];
        using var c = Open();
        // Single-character searches use the source text, because a Chinese bigram index cannot answer them.
        var single = query.Trim().Length == 1;
        using var cmd = Command(c, single ? """
            SELECT f.id,f.run_id,r.title,f.sequence,f.ocr_text,0.0 FROM frames f JOIN runs r ON r.id=f.run_id
            WHERE instr(lower(f.ocr_text),$query)>0 ORDER BY f.captured_at DESC LIMIT 50
            """ : """
            SELECT f.id,f.run_id,r.title,f.sequence,f.ocr_text,bm25(search) FROM search
            JOIN frames f ON f.id=search.frame_id JOIN runs r ON r.id=f.run_id
            WHERE search MATCH $query ORDER BY bm25(search) LIMIT 50
            """, ("$query", single ? query.Trim().ToLowerInvariant() : string.Join(" AND ", tokens.Select(t => $"\"{t}\""))));
        using var reader = cmd.ExecuteReader(); var list = new List<SearchHit>();
        while (reader.Read())
        {
            var text = reader.GetString(4); var index = text.IndexOf(tokens[0], StringComparison.OrdinalIgnoreCase);
            var start = Math.Max(0, index - 60); var snippet = text.Substring(start, Math.Min(360, text.Length - start));
            list.Add(new(reader.GetString(0), reader.GetString(1), reader.GetString(2), reader.GetInt32(3), snippet, -reader.GetDouble(5)));
        }
        return list;
    }
}
