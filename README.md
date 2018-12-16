# Oddmuse Curl

Oddmuse Curl is a fork of a very old revision of Oddmuse Mode. Use it
to edit [Oddmuse](https://oddmuse.org/) wikis such as
[Emacs Wiki](https://emacswiki.org/).

Cool features:

* VC integration
* Preview

## Keybindings

* `C-c C-b` – browse this page in a web browser
* `C-c C-c` – post the changes you made
* `C-c C-e` – edit a page
* `C-c C-f` – follow a link
* `C-c C-h` – look at the history of the page you are editing
* `C-c C-i` – insert an existing page name (avoiding typos)
* `C-c C-m` – toggle posting minor changes (often people will make a big change and continue fixing later typos using minor changes)
* `C-c C-n` – create a new page with the current date as the default page name (useful for blogging)
* `C-c C-p` – preview the current page
* `C-c C-r` – list recent changes to the wiki
* `C-c C-s` – search the wiki
* `C-c C-t` – insert HTML tag
* `C-x C-v` – revert your changes
* `C-x v l` – look at /all/ past changes of the page you are editing
* `C-x v =` – look at the diff of what you will be posting
* `C-x v u` – revert you changes

## Typical Setup

```
;;; Oddmuse

(setq oddmuse-username "AlexSchroeder")
(add-to-list 'auto-mode-alist '("/Users/alex/.emacs.d/oddmuse" . oddmuse-mode))
(autoload 'oddmuse-edit "oddmuse-curl"
  "Edit a page on an Oddmuse wiki." t)
(add-to-list 'vc-handled-backends 'oddmuse)
(defun vc-oddmuse-registered (file)
  "Handle files in `oddmuse-directory'."
  (string-match (concat "^" (expand-file-name oddmuse-directory))
		(file-name-directory file)))
```

Adding to `vc-handled-backends` and the definition of
`vc-oddmuse-registered` would be part of autoloads, if this file was
distributed with Emacs. As it stands, you could instead `(require
'vc-oddmuse)`. It’s just that I want to keep my Emacs startup speed
down and that’s why I don’t.
