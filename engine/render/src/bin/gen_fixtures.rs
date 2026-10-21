//! Deterministic fixture generator.
//!
//! Default: generate any missing fixture wavs into engine/fixtures and
//! verify every hash against MANIFEST.json.
//! --write-manifest: regenerate everything and rewrite MANIFEST.json (only
//! when fixtures change intentionally; the diff must be committed).
//! --check: verify only (used by run-tests.sh).

use render::fixtures;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let dir = fixtures::repo_fixtures_dir();
    let result = if args.iter().any(|a| a == "--write-manifest") {
        fixtures::generate_all(&dir)
            .and_then(|manifest| fixtures::write_manifest(&dir, &manifest))
            .map(|_| println!("fixtures generated, MANIFEST.json rewritten"))
    } else {
        fixtures::ensure(&dir).map(|_| {
            println!(
                "fixtures ok in {} ({} files, hashes match MANIFEST.json)",
                dir.display(),
                fixtures::FIXTURES.len()
            )
        })
    };
    if let Err(err) = result {
        eprintln!("gen-fixtures failed: {err}");
        std::process::exit(1);
    }
}
