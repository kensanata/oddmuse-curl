# Oddmuse Curl

Oddmuse Curl is a fork of a very old revision of Oddmuse Mode. Use it
to edit [Oddmuse](https://oddmuse.org/) wikis such as
[Emacs Wiki](https://emacswiki.org/).

Cool features:

* VC integration
* Preview

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
