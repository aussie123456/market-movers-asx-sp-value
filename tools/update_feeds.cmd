@echo off
rem Refreshes the saved copy of the research feeds (Substack refuses GitHub's servers) and pushes it. No Claude needed.
cd /d "%~dp0.."
"C:\Program Files\Git\bin\bash.exe" -lc "perl build.pl --feeds-only && git add data/feeds.json && (git diff --cached --quiet || git commit -q -m 'Refresh saved research feeds') && git push -q"
