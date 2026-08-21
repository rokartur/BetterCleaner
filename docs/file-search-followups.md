# File Search: odłożone poprawki

Z czterech rund review nad stroną File Search (`FileSearcher.swift`,
`FileSearchViewController.swift`) i wywołaną przez nią rundą nad `Trasher`.
Wszystkie BLOCKERy i SHOULD-FIX są naprawione.

## NIT-y

- **Dwie pętle kasowania zamiast jednej** — `AppRemover.trashUserItems` ma teraz
  te same reguły co `Trasher.trash` (wolumeny, eskalacja tylko przy braku
  uprawnień, `skipped`), ale to wciąż osobny kod. Różni się realnie jednym: jego
  błędy uprawnień składają się do wspólnego wsadu admina, zamiast pytać od razu.
  Scalenie wymagałoby, żeby `Trasher` umiał oddać pary do cudzego wsadu.

- **Wspólna fabryka `FileItem`** — `FileSearcher`, `SpotlightScanner` i
  `LeftoverScanner` budują `FileItem` trzema prawie identycznymi kawałkami kodu
  (nazwa, rozmiar, domena, data). Ruszenie tego dotyka plików spoza tego diffa,
  więc do osobnego przejścia.
- **Lokalizacja `rg`** — `ripgrepPath` sprawdza tylko `/opt/homebrew/bin`,
  `/usr/local/bin`, `/usr/bin`. Brakuje MacPorts (`/opt/local/bin/rg`) i cargo
  (`~/.cargo/bin/rg`). Użytkownik z takim `rg` widzi komunikat, że go nie ma.
- **`Kind.contentType` jako `String`** — powinno być `UTType?`, wtedy literówka
  w identyfikatorze typu jest błędem kompilacji, a nie pustym wynikiem.
- **Błędne surowe zapytanie `kMDItem`** — `mdfind` zwraca dla niego status błędu,
  ale `mdfindPaths` oddaje tylko ścieżki, więc UI pokazuje „No Matches" zamiast
  „Invalid Query". Wymaga przepchnięcia statusu przez `mdfindPaths`, co dotyka
  wszystkich skanerów, dla ścieżki używanej przez power userów.

- **Historia bez `Restore` przy `trashItem` bez `resultingItemURL`** — rekord
  zapisuje się z `recoverable: false`, więc nic nie kłamie, ale plik jest w Koszu
  wolumenu i użytkownik musi go znaleźć sam.
- **Plik na dysku zewnętrznym ma w historii `domain: "system"`** —
  `FileSearcher.swift:201` uznaje wszystko poza `$HOME` za systemowe, więc
  `TrashRestorer` prosi o hasło admina przy przywracaniu pliku, który tego nie
  wymaga. Działa, tylko niepotrzebnie pyta.

## Sprzed tego diffa

- `FileListViewController` narusza `type_body_length` (SwiftLint) — plik był za
  długi już wcześniej, ta zmiana go nie powiększyła w istotny sposób.
- `SpotlightAssociatesTests.declaredExecutableAndAlternateNamesAreSignals` pada
  na `HEAD` bez tych zmian. Zweryfikowane na odłożonym stashu.
