# PowerShell AST traversal — gotchas that silently match nothing

Both of these were hit in WUU2-CLI on 2026-09-29 while writing a script to delete dead code by
`Extent`, and **both report success while doing nothing**. Neither raises an error.

## 1. `$x = { ... }` — the RHS is a `CommandExpressionAst`, not a `ScriptBlockExpressionAst`

```powershell
# WRONG — matches zero statements, silently:
$ast.FindAll({ param($x)
    $x -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $x.Right -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
}, $true)
```

The real shape is `AssignmentStatementAst.Right` -> `CommandExpressionAst` ->
`.Expression` -> `ScriptBlockExpressionAst`. Filter on `Right -is CommandExpressionAst`
(or reach through `.Right.Expression`).

Measured on `Wuu.Core.psm1`: 749 `AssignmentStatementAst`, 23 assigning to `$event*`, and the
`ScriptBlockExpressionAst` filter found **0** of them.

## 2. `FindAll`'s second argument (`searchNestedScriptBlocks`) matters enormously

```
$ast.FindAll({ $args[0] -is [AssignmentStatementAst] }, $false)   -> 0     # !!
$ast.FindAll({ $args[0] -is [AssignmentStatementAst] }, $true)    -> 749
```

For a whole-file scan the second argument must be `$true`, or nested/most top-level statements are
not visited at all. (This codebase's tests already used `$true`; the prune script initially did not.)

## 3. Predicate form is NOT the problem

Both `{ $args[0] -is $T }` and `{ param($x) $x -is $T }` behave identically — the repo's validator
uses `$args[0]` while its tests use `param($x)`. Don't waste time rewriting the predicate when the
real cause is the node type or the nesting flag. Verify by probing, not by rewriting.

## 4. `-contains` / `-match` are CASE-INSENSITIVE — the array-membership trap

```powershell
@('$ClearComputerList') -contains '$clearComputerList'   # True  (!!)
```

A prune script keyed on `$ClearComputerList` therefore also proposed deleting `$clearComputerList`,
**18 lines of live code** that `$consoleActions.ClearComputerList` calls. Use `-ccontains` for
exact membership and `-cmatch` for exact patterns. PowerShell's case-insensitivity is a documented
landmine in this project (it killed the console shell once, via `$actions` vs `$Actions`); this is
the collection-operator version of the same class.

## 5. Writing the file: BOM, not `Set-Content`

Files with non-ASCII bytes need a UTF-8 **BOM** or PS 5.1 reads them as ANSI and a multi-byte
character eats a quote. `Set-Content -Encoding UTF8` writes BOM-less under PS 7. Use:

```powershell
[System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($true)))
```
