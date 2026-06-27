# GitHub Upload Checklist

Before uploading this package:

- Choose and add a repository license.
- Add author, affiliation, and citation details if the repository will be public.
- Confirm that no raw, patient-level, stay-level, or credentialed database files were added.
- Confirm that `03_outputs/`, local QA profiles, and rendering cache directories remain ignored.
- Run the sensitive-string scan:

```powershell
rg -n -i "password|passwd|secret|token|api[_-]?key|D:\\\\|C:\\\\|Desktop|ROG|Physionet" .
```

- Confirm that any remaining `PGPASSWORD` hits are only environment-variable instructions, not actual passwords.
- Review whether TIFF and DOCX artifacts should remain in the public repository or be moved to a release archive.
- Update the repository title and description on GitHub.

