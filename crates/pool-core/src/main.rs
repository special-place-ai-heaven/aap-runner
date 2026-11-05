use std::process::ExitCode;

fn main() -> ExitCode {
    // Lossy, not `args()`, which panics on non-Unicode; U+FFFD then fails value validation.
    let args = std::env::args_os()
        .skip(1)
        .map(|a| a.to_string_lossy().into_owned());
    ExitCode::from(aap_pool_core::cli::run(
        args,
        &mut std::io::stdout().lock(),
        &mut std::io::stderr().lock(),
    ))
}
