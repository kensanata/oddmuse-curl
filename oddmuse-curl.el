;;; oddmuse-curl.el -- edit pages on an Oddmuse wiki using curl
;; 
;; Copyright (C) 2006–2019  Alex Schroeder <alex@gnu.org>
;;           (C) 2007  rubikitch <rubikitch@ruby-lang.org>
;; 
;; Latest version:
;;   https://alexschroeder.ch/cgit/oddmuse-curl/
;; Discussion, feedback:
;;   http://www.emacswiki.org/wiki/OddmuseCurl
;; 
;; This program is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the Free
;; Software Foundation, either version 3 of the License, or (at your option)
;; any later version.
;; 
;; This program is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
;; more details.
;; 
;; You should have received a copy of the GNU General Public License along
;; with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;; 
;; A mode to edit pages on Oddmuse wikis using Emacs and the
;; command-line HTTP client `curl'.
;; 
;; Since text formatting rules depend on the wiki you're writing for,
;; the font-locking can only be an approximation.
;; 
;; Put this file in a directory on your `load-path' and 
;; add this to your init file:
;; (require 'oddmuse)
;; (oddmuse-mode-initialize)
;; And then use M-x oddmuse-edit to start editing.

;;; Code:

(eval-when-compile
  (require 'cl)
  (require 'sgml-mode)
  (require 'skeleton))

(require 'goto-addr); URL regexp
(require 'info); link face
(require 'shr); preview
(require 'xml); preview munging

;;; Options

(defcustom oddmuse-directory "~/.emacs.d/oddmuse"
  "Directory to store oddmuse pages."
  :type '(string)
  :group 'oddmuse)

(defcustom oddmuse-wikis
  '(("EmacsWiki" "https://www.emacswiki.org/emacs"
     utf-8 "uihnscuskc" nil))
  "Alist mapping wiki names to URLs.

The elements in this list are:

NAME, the name of the wiki you provide when calling `oddmuse-edit'.

URL, the base URL of the script used when posting. If the site
uses URL rewriting, then you need to extract the URL from the
edit page. Emacs Wiki, for example, usually shows an URL such as
http://www.emacswiki.org/emacs/Foo, but when you edit the page
and examine the page source, you'll find this:

    <form method=\"post\" action=\"http://www.emacswiki.org/cgi-bin/emacs\"
          enctype=\"multipart/form-data\" accept-charset=\"utf-8\"
          class=\"edit text\">...</form>

Thus, the correct value for URL is
http://www.emacswiki.org/cgi-bin/emacs.

ENCODING, a symbol naming a coding-system.

SECRET, the secret the wiki uses if it has the Question Asker
extension enabled. If you're getting 403 responses (edit denied)
eventhough you can do it from a browser, examine your cookie in
the browser. For Emacs Wiki, for example, my cookie says:

    euihnscuskc%251e1%251eusername%251eAlexSchroeder

Use `split-string' and split by \"%251e\" and you'll see that
\"euihnscuskc\" is the odd one out. The parameter name is the
relevant string (its value is always 1).

USERNAME, your optional username to provide. It defaults to
`oddmuse-username'."
  :type '(repeat (list (string :tag "Wiki")
                       (string :tag "URL")
                       (choice :tag "Coding System"
			       (const :tag "default" utf-8)
			       (symbol :tag "specify"
				       :validate (lambda (widget)
						   (unless (coding-system-p
							    (widget-value widget))
						     (widget-put widget :error
								 "Not a valid coding system")))))
		       (choice :tag "Secret"
			       (const :tag "default" "question")
			       (string :tag "specify"))
		       (choice  :tag "Username"
				(const :tag "default" nil)
				(string :tag "specify"))))
  :group 'oddmuse)

;;; Variables

(defvar oddmuse-get-command
  "curl --silent %w --form action=browse --form raw=2 --form id='%t'"
  "Command to use for publishing pages.
It must print the page to stdout.

See `oddmuse-format-command' for the formatting options.")

(defvar oddmuse-rc-command
  "curl --silent %w --form action=rc --form raw=1"
  "Command to use for Recent Changes.
It must print the RSS 3.0 text format to stdout.

See `oddmuse-format-command' for the formatting options.")

(defvar oddmuse-search-command
  "curl --silent %w --form search='%r' --form raw=1"
  "Command to use for searching regular expression.
It must print the RSS 3.0 text format to stdout.

See `oddmuse-format-command' for the formatting options.")

(defvar oddmuse-match-command
  "curl --silent %w --form action=index --form match='%r' --form raw=1"
  "Command to look for matching pages.
It must print the page names to stdout.

See `oddmuse-format-command' for the formatting options.")
  
(defvar oddmuse-post-command
  (concat "curl --silent --write-out '%{http_code}'"
          " --form title='%t'"
          " --form summary='%s'"
          " --form username='%u'"
          " --form pwd='%p'"
	  " --form %q=1"
          " --form recent_edit=%m"
	  " --form oldtime=%o"
          " --form text='<%f'"
          " '%w'")
  "Command to use for publishing pages.
It must accept the page on stdin and print the HTTP status code
on stdout.

See `oddmuse-format-command' for the formatting options.")

(defvar oddmuse-preview-command
  (concat "curl --silent"
          " --form title='%t'"
          " --form username='%u'"
          " --form pwd='%p'"
	  " --form %q=1"
          " --form recent_edit=%m"
	  " --form oldtime=%o"
	  " --form Preview=Preview"; the only difference
          " --form text='<%f'"
          " '%w'")
  "Command to use for previewing pages.
It must accept the page on stdin and print the HTML on stdout.

See `oddmuse-format-command' for the formatting options.")

(defvar oddmuse-get-index-command
  "curl --silent %w --form action=index --form raw=1"
  "Command to use for publishing index pages.
It must print the page to stdout.

See `oddmuse-format-command' for the formatting options.")

(defvar oddmuse-get-history-command
  "curl --silent %w --form action=history --form id=%t --form raw=1"
  "Command to use to get the history of a page.
It must print the page to stdout.

See `oddmuse-format-command' for the formatting options.")

(defvar oddmuse-link-pattern
  "\\<[[:upper:]]+[[:lower:]]+\\([[:upper:]]+[[:lower:]]*\\)+\\>"
  "The pattern used for finding WikiName.")

(defcustom oddmuse-username user-full-name
  "Username to use when posting.
Setting a username is the polite thing to do. You can override
this in `oddmuse-wikis'."
  :type '(string)
  :group 'oddmuse)

(defcustom oddmuse-password ""
  "Password to use when posting.
You only need this if you want to edit locked pages and you
know an administrator password."
  :type '(string)
  :group 'oddmuse)

(defcustom oddmuse-use-always-minor nil
  "If set, all edits will be minor edits by default.
This is the default for `oddmuse-minor'."
 :type '(boolean)
 :group 'oddmuse)

(defvar oddmuse-pages-hash (make-hash-table :test 'equal)
  "The wiki-name / pages pairs.
Refresh using \\[oddmuse-reload-index].")

;;; Important buffer local variables

(defvar oddmuse-wiki nil
  "The current wiki.
Must match a key from `oddmuse-wikis'.")

(defvar oddmuse-page-name nil
  "Pagename of the current buffer.")

(defun oddmuse-set-missing-variables (&optional arg)
  "Set `oddmuse-wiki' and `oddmuse-page-name', if necessary.
Force a binding of `oddmuse-wiki' if ARG is provided.

Call this function when you're running a command in a buffer that
was not previously connected to a wiki. One example would be
calling `oddmuse-post' on an ordinary file that's not in Oddmuse
Mode."
  (when (or (not oddmuse-wiki) arg)
    (set (make-local-variable 'oddmuse-wiki)
         (oddmuse-read-wiki)))
  (when (not oddmuse-page-name)
    (set (make-local-variable 'oddmuse-page-name)
         (oddmuse-read-pagename oddmuse-wiki t (buffer-name)))))

(defvar oddmuse-minor nil
  "Is this edit a minor change?")

(defvar oddmuse-ts nil
  "The timestamp of the current page's ancestor.
This is used by Oddmuse to merge changes.")

;;; Remembering the latest revision of every page

(defvar oddmuse-revisions nil
  "An alist to store the current revision we have per page.
An alist wikis containing an alist of pages and revisions.
Example:

  ((\"Alex\" ((\"Contact\" . \"58\"))))")

(defvar oddmuse-revision nil
  "A variable to bind dynamically when calling `oddmuse-format-command'.")

(defun oddmuse-revision-put (wiki page rev)
  "Store REV for WIKI and PAGE in `oddmuse-revisions'."
  (let ((w (assoc wiki oddmuse-revisions)))
    (unless w
      (setq w (list wiki)
	    oddmuse-revisions (cons w oddmuse-revisions)))
    (let ((p (assoc page w)))
      (unless p
	(setq p (list page))
	(setcdr w (cons p (cdr w))))
      (setcdr p rev))))

(defun oddmuse-revision-get (wiki page)
  "Get revision for WIKI and PAGE in `oddmuse-revisions'."
  (let ((w (assoc wiki oddmuse-revisions)))
    (when w
      (cdr (assoc page w)))))

;;; Helpers

(defsubst oddmuse-page-name (file)
  "Return the page name based on FILE."
  (file-name-nondirectory file))

(defsubst oddmuse-wiki (file)
  "Return the wiki name based on FILE."
  (file-name-nondirectory
   (directory-file-name
    (file-name-directory file))))

(defmacro with-oddmuse-file (file &rest body)
  "Bind `wiki' and `pagename' based on FILE and execute BODY."
  (declare (debug (symbolp &rest form)))
  `(let ((pagename (oddmuse-page-name ,file))
	 (wiki (oddmuse-wiki ,file)))
     ,@body))

(put 'with-oddmuse-file 'lisp-indent-function 1)
(font-lock-add-keywords 'emacs-lisp-mode '("\\<with-oddmuse-file\\>"))

(defun oddmuse-url (wiki pagename)
  "Get the URL of oddmuse wiki."
  (condition-case v
      (concat (or (cadr (assoc wiki oddmuse-wikis)) (error "Wiki not found in `oddmuse-wikis'")) "/"
	      (url-hexify-string pagename))
    (error nil)))

(defvar oddmuse-pagename-history nil
  "History of Oddmuse pages edited.")

(defun oddmuse-read-pagename (wiki &optional require default)
  "Read a pagename of WIKI with completion.
Optional arguments REQUIRE and DEFAULT are passed on to `completing-read'.
Typically you would use t and a `oddmuse-page-name', if that makes sense."
  (let ((completion-ignore-case t))
    (completing-read (if default
			 (concat "Pagename [" default "]: ")
		       "Pagename: ")
		     (oddmuse-make-completion-table wiki)
		     nil require nil
                     'oddmuse-pagename-history default)))

(defvar oddmuse-wiki-history nil
  "History of Oddmuse Wikis edited.
This is a list referring to `oddmuse-wikis'.")

(defun oddmuse-read-wiki (&optional require default)
  "Read wiki name with completion.
Optional arguments REQUIRE and DEFAULT are passed on to `completing-read'.
Typically you would use t and the current wiki, `oddmuse-wiki'.

If you want to use the current wiki unless the function was
called with C-u. This is what you want for functions that end
users call and that you might want to run on a different wiki
such as searching.

\(let* ((wiki (or (and (not current-prefix-arg) oddmuse-wiki)
		 (oddmuse-read-wiki))))
        ...)
 ...)

If you want to ask only when there is no current wiki:

\(let* ((wiki (or oddmuse-wiki (oddmuse-read-wiki)))
        ...)
 ...)

If you want to ask for a wiki and provide the current one as
default:

\(oddmuse-read-wiki t oddmuse-wiki)"
  (let ((completion-ignore-case t))
    (completing-read (if default
			 (concat "Wiki [" default "]: ")
		       "Wiki: ")
		     oddmuse-wikis
                     nil require nil
                     'oddmuse-wiki-history default)))

(defun oddmuse-pagename ()
  "Return the wiki and pagename the user wants to edit or follow.
This cannot be the current pagename!  If given the optional
argument ARG, read it from the minibuffer.  Otherwise, try to get
a pagename at point.  If this does not yield a pagename, ask the
user for a page. Also, if no wiki has been give, ask for that,
too. The pagename returned does not necessarily exist!

Use this function when following links in regular wiki buffers,
in Recent Changes, History Buffers, and also in text files and
the like."
  (let* ((arg current-prefix-arg)
	 (wiki (or (and (not arg) oddmuse-wiki)
                   (oddmuse-read-wiki)))
	 (pagename (or (and arg (oddmuse-read-pagename wiki))
		       (oddmuse-pagename-at-point)
		       (oddmuse-read-pagename wiki nil (word-at-point)))))
    (list wiki pagename)))

(defun oddmuse-pagename-if-missing ()
  "Return the default wiki and page name or ask for one."
  (if (and oddmuse-wiki oddmuse-page-name)
      (list oddmuse-wiki oddmuse-page-name)
    (oddmuse-pagename)))

(defun oddmuse-current-free-link-contents ()
  "The page name in a free link at point.
This returns \"foo\" for the following:
- [[foo]]
- [[foo|bar]]
- [[image:foo]]"
  (save-excursion
    (let* ((pos (point))
           (start (when (re-search-backward "\\[\\[\\(image:\\)?" nil t)
		    (match-end 0)))
           (end (when (search-forward "]]" (line-end-position) t)
		  (match-beginning 0))))
      (and start end (>= end pos)
           (replace-regexp-in-string
            " " "_"
	    (car (split-string
		  (buffer-substring-no-properties start end) "|")))))))

(defun oddmuse-pagename-at-point ()
  "Page name at point.
It's either a [[free link]] or a WikiWord based on
`oddmuse-current-free-link-contents' or `oddmuse-wikiname-p'."
  (let ((pagename (word-at-point)))
    (or (oddmuse-current-free-link-contents)
	(oddmuse-wikiname-p pagename))))

(defun oddmuse-wikiname-p (pagename)
  "Whether PAGENAME is WikiName or not."
  (when pagename
    (let (case-fold-search)
      (when (string-match (concat "^" oddmuse-link-pattern "$") pagename)
	pagename))))

;; (oddmuse-wikiname-p nil)
;; (oddmuse-wikiname-p "WikiName")
;; (oddmuse-wikiname-p "not-wikiname")
;; (oddmuse-wikiname-p "notWikiName")

(defun oddmuse-render-rss3 ()
  "Parse current buffer as RSS 3.0 and display it correctly."
  (save-excursion
    (let (result)
      (dolist (item (cdr (split-string (buffer-string) "\n\n")));; skip first item
	(let ((data (mapcar (lambda (line)
			      (when (string-match "^\\(.*?\\): \\(.*\\)" line)
				(cons (match-string 1 line)
				      (match-string 2 line))))
			    (split-string item "\n"))))
	  (setq result (cons data result))))
      (erase-buffer)
      (dolist (item (nreverse result))
	(insert "title:      " (cdr (assoc "title" item)) "\n"
		"version:    " (cdr (assoc "revision" item)) "\n"
		"generator:  " (cdr (assoc "generator" item)) "\n"
		"timestamp:  " (cdr (assoc "last-modified" item)) "\n\n"
		"    " (or (cdr (assoc "description" item)) ""))
	(fill-paragraph)
	(insert "\n\n"))
      (goto-char (point-min)))
    (view-mode)))

;;; processing the commands

(defun oddmuse-quote (string)
  "Quote STRING for use in shell commands."
  (if (and (stringp string)
	   (string-match "'" string))
      ;; form summary='A quote is '"'"' this!'
      (replace-regexp-in-string "'" "'\"'\"'" string t t)
    string))

(defun oddmuse-format-command (command)
  "Format COMMAND, replacing placeholders with variables.

%w `url' as provided by `oddmuse-wikis'
%t `pagename'
%s `summary' as provided by the user
%u `username' as provided by `oddmuse-wikis'
   or `oddmuse-username' if not provided
%m `oddmuse-minor'
%p `oddmuse-password'
%q `question' as provided by `oddmuse-wikis'
%o `oddmuse-ts'
%v `oddmuse-revision'
%r `regexp' as provided by the user
%f `filename' for a file to upload"
  (dolist (pair '(("%w" . url)
		  ("%t" . pagename)
		  ("%s" . summary)
		  ("%u" . oddmuse-username)
		  ("%m" . oddmuse-minor)
		  ("%p" . oddmuse-password)
		  ("%q" . question)
		  ("%o" . oddmuse-ts)
		  ("%v" . oddmuse-revision)
		  ("%r" . regexp)
		  ("%f" . filename)))
    (let* ((key (car pair))
	   (sym (cdr pair))
	   value)
      (when (boundp sym)
	(setq value (oddmuse-quote (symbol-value sym)))
	(when (eq sym 'oddmuse-minor)
	  (setq value (if value "on" "off")))
	(when (stringp value)
	  (setq command (replace-regexp-in-string key value command t t))))))
  (replace-regexp-in-string "&" "%26" command t t))

(defun oddmuse-run (mesg command wiki &optional pagename buf)
  "Print MESG and run COMMAND on the current buffer.
WIKI identifies the entry in `oddmuse-wiki' to be used and
defaults to the variable `oddmuse-wiki'.

PAGENAME is the optional page name to pass to
`oddmuse-format-command' and defaults to the variable
`oddmuse-page-name'.

MESG should be appropriate for the following uses:
  \"MESG...\"
  \"MESG...done\"
  \"MESG failed: REASON\"

Save output in BUF and report an appropriate error.  If BUF is
not provided, use the current buffer.

We check the HTML in the buffer for indications of an error. If
we find any, that will get reported."
  (let* ((max-mini-window-height 1)
	 (wiki (or wiki oddmuse-wiki))
	 (pagename (or pagename oddmuse-page-name))
	 (wiki-data (or (assoc wiki oddmuse-wikis)
			(error "Cannot find data for wiki %s" wiki)))
	 (url (nth 1 wiki-data))
	 (coding (nth 2 wiki-data))
	 (coding-system-for-read coding)
	 (coding-system-for-write coding)
	 (question (nth 3 wiki-data))
	 (oddmuse-username (or (nth 4 wiki-data) oddmuse-username)))
    (setq buf (or buf (current-buffer))
	  command (oddmuse-format-command command))
    (message "%s using %s..." mesg command)
    (shell-command command buf)
    (let ((status (with-current-buffer buf (buffer-string))))
      (cond ((string-match "<title>Error</title>" status)
	     (if (string-match "<h1>\\(.*\\)</h1>" status)
		 (error "Error %s: %s" mesg (match-string 1 status))
	       (error "Error %s: Cause unknown" status)))
	    ((string-match "^000" status)
	     (error "Strange error: %s" status))
	    (t
	     (message "%s...done (%s)" mesg status))))))

(defun oddmuse-make-completion-table (wiki)
  "Create pagename completion table for WIKI.
If available, return precomputed one."
  (or (gethash wiki oddmuse-pages-hash)
      (oddmuse-reload-index wiki)))

(defun oddmuse-reload-index (&optional wiki-arg)
  "Really fetch the list of pagenames from WIKI.
This command is used to reflect new pages to `oddmuse-pages-hash'."
  (interactive)
  (let* ((wiki (or wiki-arg
                   (oddmuse-read-wiki t oddmuse-wiki)))
         (url (cadr (assoc wiki oddmuse-wikis)))
         (command (oddmuse-format-command oddmuse-get-index-command))
         table)
    (message "Getting index of all pages...")
    (prog1
	(setq table (split-string (shell-command-to-string command)))
      (puthash wiki table oddmuse-pages-hash)
      (message "Getting index of all pages...done"))))

;;; Mode and font-locking

(defun oddmuse-mode-initialize ()
  (add-to-list 'auto-mode-alist
               `(,(expand-file-name oddmuse-directory) . oddmuse-mode)))

(defcustom oddmuse-markup
  '(oddmuse-basic-markup
    oddmuse-bbcode-markup
    oddmuse-creole-markup
    oddmuse-extended-markup
    oddmuse-usemod-markup
    oddmuse-usemod-html-markup)
  "List of markup variables used for Oddmuse markup.
For example:
\(setq oddmuse-markup '(oddmuse-markdown-markup oddmuse-basic-markup))"
  :type '(repeat
	  (choice
	   (variable-item :tag "Basic" oddmuse-basic-markup)
	   (variable-item :tag "BBcode" oddmuse-bbcode-markup)
	   (variable-item :tag "Creole" oddmuse-creole-markup)
	   (variable-item :tag "Extended" oddmuse-extended-markup)
	   (variable-item :tag "Markdown" oddmuse-markdown-markup)
	   (variable-item :tag "Usemod" oddmuse-usemod-markup)
	   (variable-item :tag "Usemod HTML" oddmuse-usemod-html-markup))))

(defvar oddmuse-markup-keywords nil
  "The actual keywords used for `oddmuse-mode'
based on the value of `oddmuse-markup'. It is recomputed
every time Oddmues mode is activated.")

(defvar oddmuse-creole-markup
  '(("^=[^=\n]+"
     0 '(face info-title-1
	      help-echo "Creole H1")); = h1
    ("^==[^=\n]+"
     0 '(face info-title-2
	      help-echo "Creole H2")); == h2
    ("^===[^=\n]+"
     0 '(face info-title-3
	      help-echo "Creole H3")); === h3
    ("^====+[^=\n]+"
     0 '(face info-title-4
	      help-echo "Creole H4")); ====h4
    ("\\_<//\\(.*\n\\)*?.*?//"
     0 '(face italic
	      help-echo "Creole italic")); //italic//
    ("\\*\\*\\(.*\n\\)*?.*?\\*\\*"
     0 '(face bold
	      help-echo "Creole bold")); **bold**
    ("__\\(.*\n\\)*?.*?__"
     0 '(face underline
	      help-echo "Creole underline")); __underline__
    ("|+=?"
     0 '(face font-lock-string-face
	      help-echo "Creole table cell"))
    ("\\\\\\\\[ \t]+"
     0 '(face font-lock-warning-face
	      help-echo "Creole line break"))
    ("^#+ "
     0 '(face font-lock-constant-face
	      help-echo "Creole ordered list"))
    ("^- "
     0 '(face font-lock-constant-face
	      help-echo "Creole ordered list"))
    ("{{{.*?}}}"
     0 '(face shadow
	      help-echo "Creole code"))
    ("^{{{\\(.*\n\\)+?}}}\n"
     0 '(face shadow
	      help-echo "Creole multiline code")))
    "Implement markup rules for the Creole markup extension.
The rule to identify multiline blocks of code doesn't really work.")

(defvar oddmuse-markdown-markup
  '(("^# .*"
     0 '(face info-title-1
	      help-echo "Markdown H1")); # h1
    ("^## .*"
     0 '(face info-title-2
	      help-echo "Markdown H2")); ## h2
    ("^### .*"
     0 '(face info-title-3
	      help-echo "Markdown H3")); ### h3
    ("^#### .*"
     0 '(face info-title-4
	      help-echo "Markdown H4")); #### h4
    ("\\[[^]]+\\]([^)]+)"
     0 '(face link
	      help-echo "Markdown link"))
    ("\\_<\\*\\([^* \n]\\([^*\n]+\n\\)*?[^*\n]*?[^* \n]\\|[^* \n]\\)\\*"
     0 '(face italic
	      help-echo "Markdown emphasis")); *emphasis*
    ("\\_<\\*\\*\\([^* \n]\\([^*\n]+\n\\)*?[^*\n]*?[^* \n]\\|[^* \n]\\)\\*\\*"
     0 '(face bold
	      help-echo "Markdown strong emphasis")); **strong emphasis**
    ("^[0-9]+\\. "
     0 '(face font-lock-constant-face
	      help-echo "Markdown ordered list"))
    ("^- "
     0 '(face font-lock-constant-face
	      help-echo "Markdown ordered list"))
    ("^```\\(.*\n\\)+?```\n"
     0 '(face shadow
	      help-echo "Markdown multiline code"))
    ("`\\([^` \n]\\([^`\n]+\n\\)*?[^`\n]*?[^` \n]\\|[^` \n]\\)`"
     0 '(face shadow
	      help-echo "Markdown code")))
    "Implement markup rules for the Markdown markup extension.
The rule to identify multiline blocks of code doesn't really work.")

(defvar oddmuse-bbcode-markup
  `(("\\[b\\]\\(.*\n\\)*?.*?\\[/b\\]"
     0 '(face bold
	      help-echo "BB code bold"))
    ("\\[i\\]\\(.*\n\\)*?.*?\\[/i\\]"
     0 '(face italic
	      help-echo "BB code italic"))
    ("\\[u\\]\\(.*\n\\)*?.*?\\[/u\\]"
     0 '(face underline
	      help-echo "BB code underline"))
    (,(concat "\\[url=" goto-address-url-regexp "\\]")
     0 '(face font-lock-builtin-face
	      help-echo "BB code url"))
    ("\\[/?\\(img\\|url\\)\\]"
     0 '(face font-lock-builtin-face
	      help-echo "BB code url or img"))
    ("\\[s\\(trike\\)?\\]\\(.*\n\\)*?.*?\\[/s\\(trike\\)?\\]"
     0 '(face strike
	      help-echo "BB code strike"))
    ("\\[/?\\(left\\|right\\|center\\)\\]"
     0 '(face font-lock-constant-face
	      help-echo "BB code alignment")))
  "Implement markup rules for the bbcode markup extension.")

(defvar oddmuse-usemod-markup
  '(("^=[^=\n]+=$"
     0 '(face info-title-1
	      help-echo "Usemod H1"))
    ("^==[^=\n]+==$"
     0 '(face info-title-2
	      help-echo "Usemod H2"))
    ("^===[^=\n]+===$"
     0 '(face info-title-3
	      help-echo "Usemod H3"))
    ("^====+[^=\n]+====$"
     0 '(face info-title-4
	      help-echo "Usemod H4"))
    ("\n\n\\( .*\n\\)+"
     0 '(face shadow
	      font-lock-multiline t
	      help-echo "Usemod block"))
    ("^[#]+ "
     0 '(face font-lock-constant-face
	      help-echo "Usemod ordered list")))
  "Implement markup rules for the Usemod markup extension.
The rule to identify indented blocks of code doesn't really work.")

(defvar oddmuse-usemod-html-markup
  '(("<\\(/?[a-z]+\\)"
     1 '(face font-lock-function-name-face
	      help-echo "Usemod HTML")))
  "Implement markup rules for the HTML option in the Usemod markup extension.")

(defvar oddmuse-extended-markup
  '(("\\*\\w+[[:word:]-%.,:;\'\"!? ]*\\*"
     0 '(face bold
	      help-echo "Markup bold"
	      nobreak t))
    ("\\_</\\w+[[:word:]-%.,:;\'\"!? ]*/"
     0 '(face italic
	      help-echo "Markup italic"
	      nobreak t))
    ("_\\w+[[:word:]-%.,:;\'\"!? ]*_"
     0 '(face underline
	      help-echo "Markup underline"
	      nobreak t)))
  "Implement markup rules for the Markup extension.")

(defvar oddmuse-basic-markup
  `(("\\[\\[.*?\\]\\]"
     0 '(face link
	      help-echo "Basic free link"))
    (,(concat "\\[" goto-address-url-regexp "\\( .+?\\)?\\]")
     0 '(face link
	      help-echo "Basic external free link"))
    ("\\[[[:upper:]]\\S-*:\\S-+ [^]\n]*\\]"
     0 '(face link
	      help-echo "Basic external interlink with text"))
    ("[[:upper:]]\\S-*:\\S-+"
     0 '(face link
	      help-echo "Basic external interlink"))
    (,oddmuse-link-pattern
     0 '(face link
	      help-echo "Basic wiki name"))
    ("^\\([*] \\)"
     0 '(face font-lock-constant-face
	      help-echo "Basic bullet list")))
  "Implement markup rules for the basic Oddmuse setup without extensions.
These rules should come come last because of such basic patterns
as [.*] which are very generic.")

(define-derived-mode oddmuse-mode text-mode "Odd"
  "Simple mode to edit wiki pages.

Use \\[oddmuse-follow] to follow links. With prefix, allows you
to specify the target page yourself.

Use \\[oddmuse-post] to post changes. With prefix, allows you to
post the page to a different wiki.

Use \\[oddmuse-edit] to edit a different page. With prefix,
forces a reload of the page instead of just popping to the buffer
if you are already editing the page.

Customize `oddmuse-wikis' to add more wikis to the list.
Customize `oddmuse-markup' to change font locking.

\\{oddmuse-mode-map}"
  (set (make-local-variable 'oddmuse-minor)
       oddmuse-use-always-minor)
  (setq indent-tabs-mode nil)

  ;; font-locking (case sensitive)
  (goto-address)
  (setq-local oddmuse-markup-keywords
	      (apply 'append (mapcar 'symbol-value oddmuse-markup)))
  (setq font-lock-defaults (list oddmuse-markup-keywords))
  (font-lock-mode 1)

  ;; HTML tags
  (set (make-local-variable 'sgml-tag-alist)
       `(("b") ("code") ("em") ("i") ("strong") ("nowiki")
	 ("pre" \n) ("tt") ("u")))
  (set (make-local-variable 'skeleton-transformation-function) 'identity)

  (make-local-variable 'oddmuse-wiki)
  (make-local-variable 'oddmuse-page-name)

  (when buffer-file-name
    (setq oddmuse-wiki (oddmuse-wiki buffer-file-name)
	  oddmuse-page-name (oddmuse-page-name buffer-file-name))
    ;; set buffer name
    (let ((name (concat oddmuse-wiki ":" oddmuse-page-name)))
      (unless (equal name (buffer-name)) (rename-buffer name))))

  ;; version control
  (set (make-local-variable 'oddmuse-ts)
       (save-excursion
	 (goto-char (point-min))
	 (if (looking-at
	      "\\([0-9]+\\) # Do not delete this line when editing!\n")
	     (prog1 (match-string 1)
	       (replace-match "")
	       (set-buffer-modified-p nil)))))

  ;; filling
  (set (make-local-variable 'fill-nobreak-predicate)
       '(oddmuse-nobreak-p))
  (set (make-local-variable 'font-lock-extra-managed-props)
       '(nobreak help-echo)))

;;; Key bindings

(defun oddmuse-nobreak-p (&optional pos)
  "Prevent line break of links.
This depends on the `link' face or the `nobreak' property: if
both the character before and after point have it, don't break."
  (if pos
      (or (get-text-property pos 'nobreak)
	  (let ((face (get-text-property pos 'face)))
	    (if (listp face)
		(memq 'link face)
	      (eq 'link face))))
    (and (oddmuse-nobreak-p (point))
	 (oddmuse-nobreak-p (1- (point))))))

(autoload 'sgml-tag "sgml-mode" t)

(define-key oddmuse-mode-map (kbd "C-c C-b") 'oddmuse-browse-this-page)
(define-key oddmuse-mode-map (kbd "C-c C-c") 'oddmuse-post)
(define-key oddmuse-mode-map (kbd "C-c C-e") 'oddmuse-edit)
(define-key oddmuse-mode-map (kbd "C-c C-f") 'oddmuse-follow)
(define-key oddmuse-mode-map (kbd "C-c C-i") 'oddmuse-insert-pagename)
(define-key oddmuse-mode-map (kbd "C-c C-y") 'oddmuse-insert-link)
(define-key oddmuse-mode-map (kbd "C-c C-l") 'oddmuse-match)
(define-key oddmuse-mode-map (kbd "C-c C-m") 'oddmuse-toggle-minor)
(define-key oddmuse-mode-map (kbd "C-c C-n") 'oddmuse-new)
(define-key oddmuse-mode-map (kbd "C-c C-p") 'oddmuse-preview)
(define-key oddmuse-mode-map (kbd "C-c C-r") 'oddmuse-rc)
(define-key oddmuse-mode-map (kbd "C-c C-s") 'oddmuse-search)
(define-key oddmuse-mode-map (kbd "C-c C-t") 'sgml-tag)
(define-key oddmuse-mode-map (kbd "C-c <") 'eimp-decrease-image-size)

;; This has been stolen from simple-wiki-edit
;;;###autoload
(defun oddmuse-toggle-minor (&optional arg)
  "Toggle minor mode state."
  (interactive)
  (let ((num (prefix-numeric-value arg)))
    (cond
     ((or (not arg) (equal num 0))
      (setq oddmuse-minor (not oddmuse-minor)))
     ((> num 0) (set 'oddmuse-minor t))
     ((< num 0) (set 'oddmuse-minor nil)))
    (message "Oddmuse Minor set to %S" oddmuse-minor)
    oddmuse-minor))

(add-to-list 'minor-mode-alist
             '(oddmuse-minor " [MINOR]"))

;;;###autoload
(defun oddmuse-insert-pagename (pagename)
  "Insert a PAGENAME of current wiki with completion.
Replaces _ with spaces again."
  (interactive (list (oddmuse-read-pagename oddmuse-wiki)))
  (insert (replace-regexp-in-string "_" " " pagename)))

(defun oddmuse-link-p (url)
  "Return URL if URL is a string containing an URL."
  (and (stringp url)
       (string-match (concat "^" goto-address-url-regexp "$") url)
       url))

(defun oddmuse-get-title-and-insert-link (url buf point)
  "Get the title for URL and insert link.
This fetches the URL asynchronously and inserts the link."
  (url-retrieve url 'oddmuse-insert-link-callback (list url buf point)))

(defun oddmuse-insert-link-callback (status url buf point)
  "Callback for `oddmuse-get-title-and-insert-link'."
  (when (re-search-forward "<title>\\(.*\\)</title>" nil t)
    (let ((title (match-string 1)))
      ;; replace some HTML escapes
      (while (string-match "&#\\([0-9]+\\);" title)
	(setq title (replace-regexp-in-string
		     (match-string 0 title)
		     (char-to-string
		      (string-to-number
		       (match-string 1 title)))
		     title)))
      (save-excursion
	(with-current-buffer buf
	  (goto-char point)
	  (insert (format "[%s %s]" url title)))))))
  
;;;###autoload
(defun oddmuse-insert-link (&optional url title)
  "Insert an Oddmuse link.
The link is taken from the optional URL argument, point (using
`ffap-url-at-point') or the clipboard or kill-ring (using
`current-kill')."
  (interactive)
  (or (oddmuse-link-p url)
      (when (setq url (ffap-url-at-point))
	(apply 'delete-region ffap-string-at-point-region)
	url)
      (setq url (oddmuse-link-p (current-kill 0 t)))
      (read-string "URL: "))
  (oddmuse-get-title-and-insert-link url (current-buffer) (point)))

;;; Major functions

(defun oddmuse-get-latest-revision (wiki pagename)
  "Return the latest revision as a string, eg. \"5\".
Requires all the variables to be bound for
`oddmuse-format-command'."
  ;; Since we don't know the most recent revision we have to fetch it
  ;; from the server every time.
  (with-temp-buffer
    (oddmuse-run "Determining latest revision" oddmuse-get-history-command wiki pagename)
    (if (re-search-forward "^revision: \\([0-9]+\\)$" nil t)
	(let ((revision (match-string 1)))
	  (message "Latest revision is %s" revision)
	  revision)
      (message "This is a new page")
      "new")))

;;;###autoload
(defun oddmuse-edit (wiki pagename)
  "Edit a page on a wiki.
WIKI is the name of the wiki as defined in `oddmuse-wikis',
PAGENAME is the pagename of the page you want to edit. If the
page is already in a buffer, pop to that buffer instead of
loading the page Use a prefix argument to force a reload of the
page. Use \\[oddmuse-reload-index] to reload the list of pages
available if you changed the URL in `oddmuse-wikis' or if other
people have been editing the wiki in the mean time."
  (interactive (oddmuse-pagename))
  (make-directory (concat oddmuse-directory "/" wiki) t)
  (let ((name (concat wiki ":" pagename)))
    (if (and (get-buffer name)
             (not current-prefix-arg))
        (pop-to-buffer (get-buffer name))
      ;; insert page content from the wiki
      (set-buffer (get-buffer-create name))
      (erase-buffer); in case of current-prefix-arg
      (oddmuse-run "Loading" oddmuse-get-command wiki pagename)
      (oddmuse-revision-put wiki pagename (oddmuse-get-latest-revision wiki pagename))
      ;; fix mode-line for VC in the new buffer because this is not a vc-checkout
      (setq buffer-file-name (concat oddmuse-directory "/" wiki "/" pagename))
      (vc-mode-line buffer-file-name 'oddmuse)
      (pop-to-buffer (current-buffer))
      ;; check for a diff (this ends with display-buffer) and bury the
      ;; buffer if there are no hunks
      (when (file-exists-p buffer-file-name)
	(message "Page loaded from the wiki but a local file also exists"))
      ;; this also changes the buffer name
      (basic-save-buffer)
      ;; this makes sure that the buffer name is set correctly
      (oddmuse-mode))))

(defalias 'oddmuse-go 'oddmuse-edit)

(defun oddmuse-reload-page ()
  "Reload the current page."
  (interactive)
  (unless (eq major-mode 'oddmuse-mode)
    (error "This only works if the current mode is in Oddmuse Mode."))
  (erase-buffer); in case of current-prefix-arg
  (oddmuse-run "Loading" oddmuse-get-command oddmuse-wiki oddmuse-page-name)
  (oddmuse-revision-put oddmuse-wiki oddmuse-page-name (oddmuse-get-latest-revision oddmuse-wiki oddmuse-page-name))
  ;; fix mode-line for VC in the new buffer because this is not a vc-checkout
  (vc-mode-line buffer-file-name 'oddmuse))

;;;###autoload
(defun oddmuse-new (wiki pagename)
  "Create a new page on a wiki.
WIKI is the name of the wiki as defined in `oddmuse-wikis'.
The pagename begins with the current date."
  (interactive 
   (list (or (and (not current-prefix-arg) oddmuse-wiki)
             (oddmuse-read-wiki))
	 (replace-regexp-in-string
	  " +" "_"
	  (read-from-minibuffer "Pagename: "
				(format-time-string "%Y-%m-%d ")))))
  (oddmuse-edit wiki pagename))

(autoload 'word-at-point "thingatpt")

;;;###autoload
(defun oddmuse-follow (wiki pagename)
  "Figure out what page we need to visit
and call `oddmuse-edit' on it."
  (interactive (oddmuse-pagename))
  (oddmuse-edit wiki pagename))

;;;###autoload
(defun oddmuse-post (summary)
  "Post the current buffer to the current wiki.
The current wiki is taken from `oddmuse-wiki'.
Use a prefix argument to override this."
  (interactive "sSummary: ")
  ;; save before setting any local variables
  (if buffer-file-name
      (basic-save-buffer)
    (write-file (make-temp-file "oddmuse")))
  ;; set oddmuse-wiki and oddmuse-page-name
  (oddmuse-set-missing-variables current-prefix-arg)
  (let ((list (gethash oddmuse-wiki oddmuse-pages-hash)))
    (when (not (member oddmuse-page-name list))
      (puthash oddmuse-wiki (cons oddmuse-page-name list) oddmuse-pages-hash)))
  (let ((filename buffer-file-name))
    ;; bind the current filename to `filename' so that it will get
    ;; picked up by `oddmuse-post-command'
    (oddmuse-run "Posting" oddmuse-post-command nil nil
		 (get-buffer-create " *oddmuse-response*")))
  (let ((revision (oddmuse-get-latest-revision oddmuse-wiki oddmuse-page-name)))
    (oddmuse-revision-put oddmuse-wiki oddmuse-page-name revision)
    (when buffer-file-name
      ;; update revision
      (vc-file-setprop buffer-file-name 'vc-working-revision revision)
      ;; update mode-line
      (vc-mode-line buffer-file-name 'oddmuse))))

;;;###autoload
(defun oddmuse-preview (&optional arg)
  "Preview the current buffer for the current wiki.
The current wiki is taken from `oddmuse-wiki'.

Use a prefix argument to view the preview using an external
browser."
  (interactive "P")
  (oddmuse-set-missing-variables)
  (unless buffer-file-name
    (setq buffer-file-name (concat oddmuse-directory "/" wiki "/" pagename)))
  (basic-save-buffer)
  (let ((buf (get-buffer-create " *oddmuse-response*"))
	(filename buffer-file-name))
    (oddmuse-run "Previewing" oddmuse-preview-command nil nil buf)
    (if arg
	(with-current-buffer buf
	  (let ((file (make-temp-file "oddmuse-preview-" nil ".html")))
	    (write-region (point-min) (point-max) file)
	    (browse-url (browse-url-file-url file))))
      (message "Rendering...")
      (pop-to-buffer "*Preview*")
      (fundamental-mode)
      (erase-buffer)
      (shr-insert-document
       (with-current-buffer buf
	 (let ((html (libxml-parse-html-region (point-min) (point-max))))
	   (oddmuse-find-node
	    (lambda (node)
	      (and (eq (xml-node-name node) 'div)
		   (string= (xml-get-attribute node 'class) "preview")))
	    html))))
      (goto-char (point-min))
      (kill-buffer buf);; prevent it from showing up after q
      (view-mode)
      (message "Rendering...done"))))

(defun oddmuse-find-node (test node)
  "Return the child of NODE that satisfies TEST.
TEST is a function that takes a node as an argument.  NODE is a
node as returned by `libxml-parse-html-region' or
`xml-parse-region'. The function recurses through the node tree."
  (if (funcall test node)
      node
    (dolist (child (xml-node-children node))
      (when (listp child)
	(let ((result (oddmuse-find-node test child)))
	  (when result
	    (cl-return result)))))))

;;;###autoload
(defun oddmuse-search (regexp)
  "Search the wiki for REGEXP.
REGEXP must be a regular expression understood by the
wiki (ie. it must use Perl syntax).
Use a prefix argument to search a different wiki."
  (interactive "sSearch term: ")
  (let* ((wiki (or (and (not current-prefix-arg) oddmuse-wiki)
		   (oddmuse-read-wiki)))
	 (name (concat "*" wiki ": search for '" regexp "'*")))
    (if (and (get-buffer name)
             (not current-prefix-arg))
        (pop-to-buffer (get-buffer name))
      (set-buffer (get-buffer-create name))
      (erase-buffer)
      (oddmuse-run "Searching" oddmuse-search-command wiki)
      (oddmuse-rc-buffer)
      (oddmuse-search-mode)
      (dolist (re (split-string regexp))
	(highlight-regexp (hi-lock-process-phrase re)))
      (set (make-local-variable 'oddmuse-wiki) wiki))))

(defun oddmuse-search-reload ()
  (error "FIXME:not implemented"))

;;;###autoload
(defun oddmuse-match (regexp)
  "Search the wiki for page names matching REGEXP.
REGEXP must be a regular expression understood by the
wiki (ie. it must use Perl syntax).
Use a prefix argument to search a different wiki."
  (interactive "sPages matching: ")
  (let* ((wiki (or (and (not current-prefix-arg) oddmuse-wiki)
		   (oddmuse-read-wiki)))
	 (name (concat "*" wiki ": matches for '" regexp "'*")))
    (if (and (get-buffer name)
             (not current-prefix-arg))
        (pop-to-buffer (get-buffer name))
      (set-buffer (get-buffer-create name))
      (erase-buffer)
      (oddmuse-run "Searching" oddmuse-match-command wiki)
      (let ((lines (split-string (buffer-string) "\n" t)))
	(erase-buffer)
	(dolist (line lines)
	  (insert "[[" (replace-regexp-in-string "_" " " line) "]]\n")))
      (oddmuse-match-mode)
      (set (make-local-variable 'oddmuse-wiki) wiki)
      (display-buffer (current-buffer)))))

(defun oddmuse-match-reload ()
  (error "FIXME:not implemented"))

;;;###autoload
(defun oddmuse-rc (&optional include-minor-edits)
  "Show Recent Changes.
With universal argument, reload."
  (interactive "P")
  (let* ((wiki (or (and (not current-prefix-arg) oddmuse-wiki)
                   (oddmuse-read-wiki)))
	 (name (concat "*" wiki ": Recent Changes*")))
    (if (and (get-buffer name) (not current-prefix-arg))
        (pop-to-buffer (get-buffer name))
      (set-buffer (get-buffer-create name))
      (setq oddmuse-wiki wiki)
      (oddmuse-rc-reload)
      (oddmuse-rc-mode)
      ;; set local variable after `oddmuse-mode' killed them
      (set (make-local-variable 'oddmuse-wiki) wiki))))

(defun oddmuse-rc-buffer ()
  "Parse current buffer as RSS 3.0 and display it correctly."
  (let ((result nil)
	(fill-column (window-width))
	(fill-prefix "  "))
    (dolist (item (cdr (split-string (buffer-string) "\n\n" t)));; skip first item
      (let ((data (mapcar (lambda (line)
			    (when (string-match "^\\(.*?\\): \\(.*\\)" line)
			      (cons (intern (match-string 1 line))
				    (match-string 2 line))))
			  (split-string item "\n" t))))
	(setq result (cons data result))))
    (erase-buffer)
    (dolist (item (nreverse result))
      (let ((title (cdr (assq 'title item)))
	    (generator (cdr (assq 'generator item)))
	    (description (cdr (assq 'description item)))
	    (minor (cdr (assq 'minor item))))
	(insert "[[" title "]] – "
		(propertize generator 'font-lock-face 'shadow))
	(when minor
	  (insert " [minor]"))
	(newline)
	(when description
	  (save-restriction
	    (narrow-to-region (point) (point))
	    (insert fill-prefix description)
	    (fill-paragraph))
	  (newline))))
    (goto-char (point-min))))

(defun oddmuse-rc-reload ()
  "Reload Recent Changes for an Oddmuse wiki.
You probably want to make sure that the buffer is in
`oddmuse-rc-mode' and that `oddmuse-wiki' is set."
  (interactive)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (oddmuse-run "Load recent changes" oddmuse-rc-command oddmuse-wiki)
    (oddmuse-rc-buffer)))

(define-derived-mode oddmuse-view-mode oddmuse-mode ""
  "A minor mode to view Oddmuse data like search results."
  (setq buffer-read-only t))

(define-key oddmuse-view-mode-map (kbd "C-c C-e") 'oddmuse-edit)
(define-key oddmuse-view-mode-map (kbd "C-c C-f") 'oddmuse-follow)
(define-key oddmuse-view-mode-map (kbd "C-c C-l") 'oddmuse-match)
(define-key oddmuse-view-mode-map (kbd "C-c C-n") 'oddmuse-new)
(define-key oddmuse-view-mode-map (kbd "C-c C-r") 'oddmuse-rc)
(define-key oddmuse-view-mode-map (kbd "C-c C-s") 'oddmuse-search)
(define-key oddmuse-view-mode-map (kbd "RET") 'oddmuse-follow)
(define-key oddmuse-view-mode-map (kbd "q") 'bury-buffer)

(define-derived-mode oddmuse-rc-mode oddmuse-view-mode "RC"
  "Show Recent Changes for an Oddmuse wiki.")

(define-key oddmuse-rc-mode-map (kbd "g") 'oddmuse-rc-reload)

(define-derived-mode oddmuse-search-mode oddmuse-view-mode "Search"
  "Show search results for an Oddmuse wiki.")

(define-key oddmuse-search-mode-map (kbd "g") 'oddmuse-search-reload)

(define-derived-mode oddmuse-match-mode oddmuse-view-mode "Match"
  "Show match results for an Oddmuse wiki.")

(define-key oddmuse-match-mode-map (kbd "g") 'oddmuse-match-reload)

(defun oddmuse-history (wiki pagename)
  "Show the history for PAGENAME on WIKI.
Compared to `vc-oddmuse-print-log' this only prints the revisions
that can actually be retrieved (for diff and rollback)."
  (interactive (oddmuse-pagename-if-missing))
  (let ((name (concat "*" wiki ": history for " pagename "*")))
    (if (and (get-buffer name)
	     (not current-prefix-arg))
	(pop-to-buffer (get-buffer name))
      (set-buffer (get-buffer-create name))
      (erase-buffer)
      (oddmuse-run "History" oddmuse-get-history-command wiki pagename)
      (oddmuse-mode)
      (set (make-local-variable 'oddmuse-wiki) wiki))))

;;;###autoload
(defun emacswiki-post (&optional pagename summary)
  "Post the current buffer to the EmacsWiki.
If this command is invoked interactively: with prefix argument,
prompts for pagename, otherwise set pagename as basename of
`buffer-file-name'.

This command is intended to post current EmacsLisp program easily."
  (interactive)
  (let* ((oddmuse-wiki "EmacsWiki")
         (oddmuse-page-name (or pagename
                                (and (not current-prefix-arg)
                                     buffer-file-name
                                     (file-name-nondirectory buffer-file-name))
                                (oddmuse-read-pagename oddmuse-wiki)))
         (summary (or summary (read-string "Summary: "))))
    (oddmuse-post summary)))

;;;###autoload
(defun oddmuse-browse-page (wiki pagename)
  "Ask a WWW browser to load an Oddmuse page.
WIKI is the name of the wiki as defined in `oddmuse-wikis',
PAGENAME is the pagename of the page you want to browse."
  (interactive (oddmuse-pagename))
  (browse-url (oddmuse-url wiki pagename)))

;;;###autoload
(defun oddmuse-browse-this-page ()
  "Ask a WWW browser to load current oddmuse page."
  (interactive)
  (oddmuse-browse-page oddmuse-wiki oddmuse-page-name))

;;;###autoload
(defun oddmuse-kill-url ()
  "Make the URL of current oddmuse page the latest kill in the kill ring."
  (interactive)
  (kill-new (oddmuse-url oddmuse-wiki oddmuse-page-name)))

(provide 'oddmuse-curl)

;;; oddmuse-curl.el ends here
