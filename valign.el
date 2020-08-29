;;; valign.el --- Visually align tables      -*- lexical-binding: t; -*-

;; Author: Yuan Fu <casouri@gmail.com>
;; URL: https://github.com/casouri/valign
;; Version: 2.0.0
;; Keywords: convenience
;; Package-Requires: ((emacs "26.0"))

;;; This file is NOT part of GNU Emacs

;;; Commentary:
;;
;; This package provides visual alignment for Org and Markdown tables
;; on GUI Emacs.  It can properly align tables containing
;; variable-pitch font, CJK characters and images.  In the meantime,
;; the text-based alignment generated by Org mode (or Markdown mode)
;; is left untouched.
;;
;; To use this package, load it and run M-x valign-mode RET.  And any
;; Org tables in Org mode should be automatically aligned.  If you want
;; to align a table manually, run M-x valign-table RET on a table.
;;
;; Valign provides two styles of separator, |-----|-----|, and
;; |           |.  Customize ‘valign-separator-row-style’ to set a
;; style.
;;
;; TODO
;; - Support org-ident. It uses line-prefix, and we don’t support it.
;; - Hided links in markdown still occupy the full length of the link,
;;   because it uses character composition, which we don’t support.

;;; Code:
;;

(require 'cl-lib)
(require 'pcase)

(defcustom valign-lighter " valign"
  "The lighter string used by function `valign-mode'."
  :group 'valign
  :type 'string)

;;; Backstage

(define-error 'valign-bad-cell "Valign encountered a invalid table cell")
(define-error 'valign-not-gui "Valign only works in GUI environment")
(define-error 'valign-not-on-table "Valign is asked to align a table, but the point is not on one")

(defun valign--cell-alignment ()
  "Return how is current cell aligned.
Return 'left if aligned left, 'right if aligned right.
Assumes point is after the left bar (“|”).
Doesn’t check if we are in a cell."
  (save-excursion
    (if (looking-at " [^ ]")
        'left
      (if (not (search-forward "|" nil t))
          (signal 'valign-bad-cell nil)
        (if (looking-back
             "[^ ] |" (max (- (point) 3) (point-min)))
            'right
          'left)))))

;; (if (string-match (rx (seq (* " ")
;;                            ;; e.g., “5.”, “5.4”
;;                            (or (seq (? (or "-" "+"))
;;                                     (+ digit)
;;                                     (? "\\.")
;;                                     (* digit))
;;                                ;; e.g., “.5”
;;                                (seq (? (or "-" "+"))
;;                                     "\\."
;;                                     (* digit)))
;;                            (* " ")))
;;                   (buffer-substring p (1- (point))))
;;     'right 'left)

(defun valign--cell-width ()
  "Return the pixel width of the cell at point.
Assumes point is after the left bar (“|”).
Return nil if not in a cell."
  ;; We assumes:
  ;; 1. Point is after the left bar (“|”).
  ;; 2. Cell is delimited by either “|” or “+”.
  ;; 3. There is at least one space on either side of the content,
  ;;    unless the cell is empty.
  ;; IOW: CELL      := <DELIM>(<EMPTY>|<NON-EMPTY>)<DELIM>
  ;;      EMPTY     := <SPACE>+
  ;;      NON-EMPTY := <SPACE>+<NON-SPACE>+<SPACE>+
  ;;      DELIM     := | or +
  (let (start)
    (save-excursion
      (skip-chars-forward " ")
      (setq start (point))
      (if (looking-at-p "[|]")
          0
        (if (not (search-forward "|" nil t))
            (signal 'valign-bad-cell nil)
          ;; We are at the right “|”
          (goto-char (match-beginning 0))
          (skip-chars-backward " ")
          (valign--pixel-width-from-to start (point)))))))

;; We used to use a custom functions that calculates the pixel text
;; width that doesn’t require a live window.  However that function
;; has some limitations, including not working right with face remapping.
;; With this function we can avoid some of them.  However we still can’t
;; get the true tab width, see comment in ‘valgn--tab-width’ for more.
(defun valign--pixel-width-from-to (from to)
  "Return the width of the glyphs from FROM (inclusive) to TO (exclusive).
The buffer has to be in a live window.  FROM has to be less than TO.
Unlike ‘valign--glyph-width-at-point’, this function can properly
calculate images pixel width.  Valign display properties must be
cleaned before using this."
  (- (car (window-text-pixel-size
           (get-buffer-window (current-buffer)) from to))
     ;; FIXME: Workaround.
     (if (bound-and-true-p display-line-numbers-mode)
         (line-number-display-width 'pixel)
       0)))

(defun valign--separator-p ()
  "If the current cell is actually a separator.
Assume point is after the left bar (“|”)."
  (or (eq (char-after) ?:) ;; Markdown tables.
      (eq (char-after) ?-)))

(defun valign--alignment-from-seperator ()
  "Return the alignment of this column.
Assumes point is after the left bar (“|”) of a separator
cell.  We don’t distinguish between left and center aligned."
  (save-excursion
    (if (eq (char-after) ?:)
        'left
      (skip-chars-forward "-")
      (if (eq (char-after) ?:)
          'right
        'left))))

(defmacro valign--do-row (row-idx-sym limit &rest body)
  "Go to each row’s beginning and evaluate BODY.
At each row, stop at the beginning of the line.  Start from point
and stop at LIMIT.  ROW-IDX-SYM is bound to each row’s
index (0-based)."
  (declare (indent 2))
  `(progn
     (setq ,row-idx-sym 0)
     (while (<= (point) ,limit)
       (beginning-of-line)
       ,@body
       (forward-line)
       (cl-incf ,row-idx-sym))))

(defmacro valign--do-column (column-idx-sym &rest body)
  "Go to each column in the row and evaluate BODY.
Start from point and stop at the end of the line.  Stop after the
cell bar (“|”) in each iteration.
COLUMN-IDX-SYM is bound to the index of the column (0-based)."
  (declare (indent 1))
  `(progn
     (setq ,column-idx-sym 0)
     (while (search-forward "|" (line-end-position) t)
       ;; Unless we are after the last bar.
       (unless (looking-at "[^|]*\n")
         ,@body)
       (cl-incf ,column-idx-sym))))

(defun valign--alist-to-list (alist)
  "Convert an ALIST ((0 . a) (1 . b) (2 . c)) to (a b c)."
  (let ((inc 0) return-list)
    (while (alist-get inc alist)
      (push (alist-get inc alist)
            return-list)
      (cl-incf inc))
    (reverse return-list)))

(defun valign--calculate-cell-width (limit)
  "Return a list of column widths.
Each column width is the largest cell width of the column.
Start from point, stop at LIMIT."
  (let (row-idx column-idx column-width-alist)
    (ignore row-idx)
    (save-excursion
      (valign--do-row row-idx limit
        (valign--do-column column-idx
          ;; Point is after the left “|”.
          ;;
          ;; Calculate this column’s pixel width, record it if it
          ;; is the largest one for this column.
          (unless (valign--separator-p)
            (let ((oldmax (alist-get column-idx column-width-alist))
                  (cell-width (valign--cell-width)))
              ;; Why “=”: if cell-width is 0 and the whole column is 0,
              ;; still record it.
              (if (>= cell-width (or oldmax 0))
                  (setf (alist-get column-idx column-width-alist)
                        cell-width)))))))
    ;; Turn alist into a list.
    (mapcar (lambda (width) (+ width 16))
            (valign--alist-to-list column-width-alist))))

(cl-defmethod valign--calculate-alignment ((type (eql markdown)) limit)
  "Return a list of alignments ('left or 'right) for each column.
TYPE must be 'markdown.  Start at point, stop at LIMIT."
  (ignore type)
  (let (row-idx column-idx column-alignment-alist)
    (ignore row-idx)
    (save-excursion
      (valign--do-row row-idx limit
        (valign--do-column column-idx
          (when (valign--separator-p)
            (setf (alist-get column-idx column-alignment-alist)
                  (valign--alignment-from-seperator)))))
      (valign--alist-to-list column-alignment-alist))))

(cl-defmethod valign--calculate-alignment ((type (eql org)) limit)
  "Return a list of alignments ('left or 'right) for each column.
TYPE must be 'org.  Start at point, stop at LIMIT."
  ;; Why can’t infer the alignment on each cell by its space padding?
  ;; Because the widest cell of a column has one space on both side,
  ;; making it impossible to infer the alignment.
  (ignore type)
  (let (column-idx column-alignment-alist row-idx)
    (ignore row-idx)
    (save-excursion
      (valign--do-row row-idx limit
        (valign--do-column column-idx
          (when (not (valign--separator-p))
            (setf (alist-get column-idx column-alignment-alist)
                  (cons (valign--cell-alignment)
                        (alist-get column-idx column-alignment-alist))))))
      ;; Now we have an alist
      ;; ((0 . (left left right left ...) (1 . (...))))
      ;; For each column, we take the majority.
      (cl-labels ((majority (list)
                            (let ((left-count (cl-count 'left list))
                                  (right-count (cl-count 'right list)))
                              (if (> left-count right-count)
                                  'left 'right))))
        (mapcar #'majority
                (valign--alist-to-list column-alignment-alist))))))

(defun valign--at-table-p ()
  "Return non-nil if point is in a table."
  (save-excursion
    (beginning-of-line)
    (let ((face (plist-get (text-properties-at (point)) 'face)))
      ;; Don’t align tables in org blocks.
      (and (looking-at "[ \t]*|")
           (not (and (consp face)
                     (or (equal face '(org-block))
                         (equal (plist-get face :inherit)
                                '(org-block)))))))))

(defun valign--beginning-of-table ()
  "Go backward to the beginning of the table at point.
Assumes point is on a table."
  (beginning-of-line)
  (let ((p (point)))
    (catch 'abort
      (while (looking-at "[ \t]*|")
        (setq p (point))
        (if (eq (point) (point-min))
            (throw 'abort nil))
        (forward-line -1)
        (beginning-of-line)))
    (goto-char p)))

(defun valign--end-of-table ()
  "Go forward to the end of the table at point.
Assumes point is on a table."
  (end-of-line)
  (while (looking-at "\n[ \t]*|")
    (forward-line)
    (end-of-line)))

(defun valign--put-text-property (beg end xpos)
  "Put text property on text from BEG to END.
The text property asks Emacs do display the text as
white space stretching to XPOS, a pixel x position."
  (with-silent-modifications
    (put-text-property
     beg end 'display
     `(space :align-to (,xpos)))))

(defun valign--put-face-overlay (face beg end)
  "Put FACE overlay between BEG and END."
  (let* ((ov-list (overlays-in beg end))
         (ov (make-overlay beg end nil t nil)))
    (dolist (ov ov-list)
      (when (overlay-get ov 'valign)
        (delete-overlay ov)))
    (overlay-put ov 'evaporate t)
    (overlay-put ov 'face face)
    (overlay-put ov 'valign t)))

(defvar valign-fancy-bar)
(defun valign--maybe-render-bar (point)
  "Make the character at POINT a full height bar.
But only if `valign-fancy-bar' is non-nil."
  (when valign-fancy-bar
    (valign--render-bar point)))

(defun valign--fancy-bar-cursor-fn (window prev-pos action)
  "Run when point enters or left a fancy bar.
Because the bar is so thin, the cursor disappears in it.  We
expands the bar so the cursor is visible.  'cursor-intangible
doesn’t work because it prohibits you to put the cursor at BOL.

WINDOW is just window, PREV-POS is the previous point of cursor
before event, ACTION is either 'entered or 'left."
  (ignore window)
  (with-silent-modifications
    (pcase action
      ('entered (put-text-property
                 (point) (1+ (point))
                 'display (if (eq cursor-type 'bar)
                              '(space :width (3)) " ")))
      ('left (put-text-property prev-pos (1+ prev-pos)
                                'display '(space :width (1)))))))

(defun valign--render-bar (point)
  "Make the character at POINT a full-height bar."
  (with-silent-modifications
    (put-text-property
     point (1+ point) 'display '(space :width (1)))
    (put-text-property point (1+ point)
                       'cursor-sensor-functions
                       '(valign--fancy-bar-cursor-fn))
    (valign--put-face-overlay '(:inverse-video t) point (1+ point))))

(defun valign--clean-text-property (beg end)
  "Clean up the display text property between BEG and END."
  (with-silent-modifications
    (put-text-property beg end 'cursor-sensor-functions nil))
  (let ((ov-list (overlays-in beg end)))
    (dolist (ov ov-list)
      (when (overlay-get ov 'valign)
        (delete-overlay ov))))
  ;; TODO ‘text-property-search-forward’ is Emacs 27 feature.
  (if (boundp 'text-property-search-forward)
      (save-excursion
        (let (match)
          (goto-char beg)
          (while (and (setq match
                            (text-property-search-forward
                             'display nil (lambda (_ p)
                                            (and (consp p)
                                                 (eq (car p) 'space)))))
                      (< (point) end))
            (with-silent-modifications
              (put-text-property (prop-match-beginning match)
                                 (prop-match-end match)
                                 'display nil)))))
    ;; Before Emacs 27.
    (let (display tab-end (p beg) last-p)
      (while (not (eq p last-p))
        (setq last-p p
              p (next-single-char-property-change p 'display nil end))
        (when (and (setq display
                         (plist-get (text-properties-at p) 'display))
                   (consp display)
                   (eq (car display) 'space))
          ;; We are at the beginning of a tab, now find the end.
          (setq tab-end (next-single-char-property-change
                         p'display nil end))
          ;; Remove text property.
          (with-silent-modifications
            (put-text-property p tab-end 'display nil)))))))

(cl-defmethod valign--align-separator-row
  (type (style (eql single-column)) pos-list)
  "Align the separator row (|---+---|) as “|---------|”.
Assumes the point is after the left bar (“|”).  TYPE can be
either 'org-mode or 'markdown, it doesn’t make any difference.
STYLE is 'single-column.  POS-LIST is a list of each column’s
right bar’s position."
  (ignore type style)
  (let ((p (point))
        ;; Position of the right-most bar.
        (total-width (car (last pos-list))))
    (when (search-forward "|" nil t)
      (valign--put-text-property p (1- (point)) total-width)
      ;; Render the right bar.
      (valign--maybe-render-bar (1- (point)))
      ;; Put strike-through.
      (valign--put-face-overlay '(:strike-through t) p (1- (point))))))

(defun valign--separator-row-add-overlay (beg end right-pos)
  "Add overlay to a separator row’s “cell”.
Cell ranges from BEG to END, the pixel position RIGHT-POS marks
the position for the right bar (“|”).
Assumes point is on the right bar or plus sign."
  ;; Make “+” look like “|”
  (if valign-fancy-bar
      ;; Render the right bar.
      (valign--render-bar end)
    (when (eq (char-after end) ?+)
      (with-silent-modifications
        (put-text-property end (1+ end) 'display "|"))))
  ;; Markdown row
  (when (eq (char-after beg) ?:)
    (setq beg (1+ beg)))
  (when (eq (char-before end) ?:)
    (setq end (1- end)
          right-pos (- right-pos
                       (valign--glyph-width-at-point (1- end)))))
  ;; End of Markdown
  (valign--put-text-property beg end right-pos)
  ;; Put strike-through.
  (valign--put-face-overlay '(:strike-through t) beg end))

(cl-defmethod valign--align-separator-row
  (type (style (eql multi-column)) pos-list)
  "Align the separator row in multi column style.
TYPE can be 'org-mode or 'markdown-mode, STYLE is 'multi-column.
POS-LIST is a list of positions for each column’s right bar."
  (ignore type style)
  (let ((p (point))
        (col-idx 0)
        (max-col (1- (length pos-list)))
        (seperator-p (valign--separator-p)))
    (while (and (< (point) (point-max))
                (<= col-idx max-col)
                (re-search-forward "[+|]" (line-end-position) t))
      ;; Separator rows that has empty cells (|----|    |----|)
      ;; is also possible.  `seperator-p' is t only for |----|.
      (if seperator-p
          (valign--separator-row-add-overlay
           p (1- (point)) (nth col-idx pos-list))
        (valign--put-text-property
         p (1- (point)) (nth col-idx pos-list)))
      (cl-incf col-idx)
      (setq p (point))
      (setq seperator-p (valign--separator-p)))))

(defun valign--guess-table-type ()
  "Return either 'org or 'markdown."
  (cond ((derived-mode-p 'org-mode 'org-agenda-mode) 'org)
        ((derived-mode-p 'markdown-mode) 'markdown)
        ((string-match-p "org" (symbol-name major-mode)) 'org)
        ((string-match-p "markdown" (symbol-name major-mode)) 'markdown)
        (t 'org)))

;;; Userland

(defcustom valign-separator-row-style 'multi-column
  "The style of the separator row of a table.
Valign can render it as “|-----------|”
or as “|-----|-----|”.  Set this option to 'single-column
for the former, and 'multi-column for the latter.
You need to restart valign mode or realign tables for this
setting to take effect."
  :type '(choice
          (const :tag "Multiple columns" multi-column)
          (const :tag "A single column" single-column))
  :group 'valign)

(defcustom valign-fancy-bar nil
  "Non-nil means to render bar as a full-height line.
You need to restart valign mode for this setting to take effect."
  :type '(choice
          (const :tag "Enable fancy bar" t)
          (const :tag "Disable fancy bar" nil))
  :group 'valign)

(defun valign-table ()
  "Visually align the table at point."
  (interactive)
  (condition-case nil
      (save-excursion
        (if (not window-system)
            (signal 'valign-not-gui nil))
        (if (not (valign--at-table-p))
            (signal 'valign-not-on-table nil))
        (valign-table-1))
    (valign-early-termination nil)
    ((valign-bad-cell valign-not-gui valign-not-on-table) nil)))

(defun valign-table-1 ()
  "Visually align the table at point."
  (let (end column-width-list column-idx pos ssw bar-width
            separator-row-point-list rev-list
            column-alignment-list at-sep-row right-bar-pos
            row-idx)
    (ignore row-idx)
    ;; ‘separator-row-point-list’ marks the point for each
    ;; separator-row, so we can later come back and align them.
    ;; ‘rev-list’ is the reverse list of right positions of each
    ;; separator row cell.  ‘at-sep-row’ t means we are at
    ;; a separator row.
    (valign--end-of-table)
    (setq end (point))
    (valign--beginning-of-table)
    (valign--clean-text-property (point) end)
    (setq column-width-list
          (valign--calculate-cell-width end)
          column-alignment-list
          (valign--calculate-alignment
           (valign--guess-table-type) end))
    ;; Iterate each cell and apply tab stops.
    (valign--do-row row-idx end
      (valign--do-column column-idx
        (save-excursion
          ;; Check there is a right bar.
          (when (save-excursion
                  (search-forward "|" (line-end-position) t)
                  (setq right-bar-pos (match-beginning 0)))
            ;; Can’t put this in the save-excursion, donno why.
            ;; Render the right bar of each cell.
            (valign--maybe-render-bar right-bar-pos)
            ;; We are after the left bar (“|”).
            ;; Start aligning this cell.
            ;;      Pixel width of the column
            (let* ((col-width (nth column-idx column-width-list))
                   (alignment (nth column-idx column-alignment-list))
                   ;; Pixel width of the cell.
                   (cell-width (valign--cell-width))
                   tab-width tab-start tab-end)
              ;; single-space-width
              (unless ssw (setq ssw (valign--pixel-width-from-to
                                     (point) (1+ (point)))))
              (unless bar-width (setq bar-width
                                      (valign--pixel-width-from-to
                                       (1- (point)) (point))))
              ;; Initialize some numbers when we are at a new
              ;; line.  ‘pos’ is the pixel position of the
              ;; current point, i.e., after the left bar.
              (when (eq column-idx 0)
                (when (valign--separator-p)
                  (push (point) separator-row-point-list))
                ;; Render the first bar of the line.
                (valign--maybe-render-bar (1- (point)))
                (unless (valign--separator-p)
                  (setq rev-list nil))
                (setq at-sep-row (if (valign--separator-p) t nil))
                (setq pos (valign--pixel-width-from-to
                           (line-beginning-position) (point))))
              ;; Align cell.
              (cond ((eq cell-width 0)
                     ;; 1) Empty cell.
                     (setq tab-start (point))
                     (skip-chars-forward " ")
                     (if (< (- (point) tab-start) 2)
                         (valign--put-text-property
                          tab-start (point) (+ pos col-width ssw))
                       ;; When possible, we try to add two tabs
                       ;; and the point can appear in the middle
                       ;; of the cell, instead of on the very
                       ;; left or very right.
                       (valign--put-text-property
                        tab-start
                        (1+ tab-start)
                        (+ pos (/ col-width 2) ssw))
                       (valign--put-text-property
                        (1+ tab-start) (point)
                        (+ pos col-width ssw))))
                    ;; 2) Separator row.  We don’t align the separator
                    ;; row yet, but will come back to it.
                    ((valign--separator-p) nil)
                    ;; 3) Normal cell.
                    (t (pcase alignment
                         ;; 3.1) Align a left-aligned cell.
                         ('left (search-forward "|" nil t)
                                (backward-char)
                                (setq tab-end (point))
                                (skip-chars-backward " ")
                                (valign--put-text-property
                                 (point) tab-end
                                 (+ pos col-width ssw)))
                         ;; 3.2) Align a right-aligned cell.
                         ('right (setq tab-width
                                       (- col-width cell-width))
                                 (setq tab-start (point))
                                 (skip-chars-forward " ")
                                 (valign--put-text-property
                                  tab-start (point)
                                  (+ pos tab-width))))))
              ;; Update ‘pos’ for the next cell.
              (setq pos (+ pos col-width bar-width ssw))
              (unless at-sep-row
                (push (- pos bar-width) rev-list)))))))
    ;; After aligning all rows, align the separator row.
    (dolist (row-point separator-row-point-list)
      (goto-char row-point)
      (valign--align-separator-row (valign--guess-table-type)
                                   valign-separator-row-style
                                   (reverse rev-list)))))

;;; Mode intergration

(defun valign-table-quiet ()
  "Align table but don’t emit any errors."
  (condition-case err
      (valign-table)
    (error (message "Valign error when aligning table: %s"
                    (error-message-string err)))))

(defun valign-region (&optional beg end)
  "Align tables between BEG and END.
Supposed to be called from jit-lock.
Force align if FORCE non-nil."
  ;; Text sized can differ between frames, only use current frame.
  ;; We only align when this buffer is in a live window, because we
  ;; need ‘window-text-pixel-size’ to calculate text size.
  (let ((beg (or beg (point-min)))
        (end (or end (point-max))))
    (when (window-live-p (get-buffer-window nil (selected-frame)))
      (save-excursion
        (goto-char beg)
        (while (and (search-forward "|" nil t)
                    (< (point) end))
          (valign-table-quiet)
          (valign--end-of-table))
        (with-silent-modifications
          (put-text-property beg (point) 'valign-init t)))))
  (cons 'jit-lock-bounds (cons beg end)))

(defvar valign-mode)
(defun valign--buffer-advice (&rest _)
  "Realign whole buffer."
  (when valign-mode (valign-region)))

;; When an org link is in an outline fold, it’s full length
;; is used, when the subtree is unveiled, org link only shows
;; part of it’s text, so we need to re-align.  This function
;; runs before the region is flagged. When the text
;; is shown, jit-lock will make valign realign the text.
(defun valign--flag-region-advice (beg end flag &optional _)
  "Valign hook, realign table between BEG and END.
FLAG is the same as in ‘org-flag-region’."
  (when (and valign-mode (not flag))
    (valign-region beg end)))

(defun valign--tab-advice (&rest _)
  "Force realign after tab so user can force realign."
  (when valign-mode
    (save-excursion
      (when-let ((on-table (valign--at-table-p))
                 (beg (progn (valign--beginning-of-table) (point)))
                 (end (progn (valign--end-of-table) (point))))
        (with-silent-modifications
          (put-text-property beg end 'fontified nil))))))

(defun valign-reset-buffer ()
  "Remove alignment in the buffer."
  ;; TODO Use the new Emacs 27 function.
  ;; Remove text properties
  (with-silent-modifications
    (valign--clean-text-property (point-min) (point-max))
    ;; Remove fancy bar’s text properties.
    (put-text-property (point-min) (point-max) 'face nil)
    (put-text-property (point-min) (point-max) 'font-lock-face nil)
    (jit-lock-refontify)))

(defun valign-remove-advice ()
  "Remove advices added by valign."
  (interactive)
  (dolist (fn '(org-table--align-field
                markdown-table-align))
    (advice-remove fn #'valign--tab-advice))
  (dolist (fn '(text-scale-increase
                text-scale-decrease
                org-agenda-finalize-hook))
    (advice-remove fn #'valign--buffer-advice))
  (dolist (fn '(org-flag-region outline-flag-region))
    (advice-remove fn #'valign--flag-region-advice)))

;;; Userland

;;;###autoload
(define-minor-mode valign-mode
  "Visually align Org tables."
  :require 'valign
  :group 'valign
  :lighter valign-lighter
  (if (and valign-mode window-system)
      (progn
        (add-hook 'jit-lock-functions #'valign-region 98 t)
        (dolist (fn '(org-table--align-field
                      markdown-table-align))
          (advice-add fn :before #'valign--tab-advice))
        (dolist (fn '(text-scale-increase
                      text-scale-decrease
                      org-agenda-finalize-hook
                      org-toggle-inline-images))
          (advice-add fn :after #'valign--buffer-advice))
        (dolist (fn '(org-flag-region outline-flag-region))
          (advice-add fn :after #'valign--flag-region-advice))
        (if valign-fancy-bar (cursor-sensor-mode))
        (jit-lock-refontify))
    (remove-hook 'jit-lock-functions #'valign-region t)
    (valign-reset-buffer)
    (cursor-sensor-mode -1)))

(provide 'valign)

;;; valign.el ends here

;; Local Variables:
;; sentence-end-double-space: t
;; End:
