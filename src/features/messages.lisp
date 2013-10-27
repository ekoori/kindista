;;; Copyright 2012-2013 CommonGoods Network, Inc.
;;;
;;; This file is part of Kindista.
;;;
;;; Kindista is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU Affero General Public License as published
;;; by the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.
;;;
;;; Kindista is distributed in the hope that it will be useful, but WITHOUT
;;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public
;;; License for more details.
;;;
;;; You should have received a copy of the GNU Affero General Public License
;;; along with Kindista.  If not, see <http://www.gnu.org/licenses/>.

(in-package :kindista)

(defun result-gratitude-p (result)
  (eq (result-type result) :gratitude))

(defun users-with-new-mail ()
  (iter (for id in (hash-table-keys *db*))
        (let ((new-items (new-inbox-items id)))
          (when (and (eq (db id :type) :person)
                     (> new-items 0))
            (collect id)))))

(defun new-inbox-items (&optional (userid *userid*))
  (loop for item in (all-inbox-items :id userid)
        while (< (or (db userid :last-checked-mail) 0) (result-time item))
        unless (case (result-type item)
                 (:conversation
                   (eql (db (db (result-id item) :latest-comment) :by)
                        userid))
                 (:reply
                   (eql (db (db (result-id item) :latest-comment) :by)
                        userid))
                 (:gratitude
                   (eql (db (result-id item) :author) userid)))
        counting item into new-items
        finally (return new-items)))

(defun migrate-to-new-inboxes ()
  (dolist (id (hash-table-keys *db*)) ;8941
    (let ((data (db id))
          (new-people-format (list :read (list) :unread (list))))
      (when (or (eq (getf data :type) :conversation)
                (eq (getf data :type) :reply))
        (dolist (person (getf data :people))
          (if (and (cdr person)
                   (< (db (cdr person) :created)
                      (+ (or (db (car person) :last-checked-mail)
                             0)
                         1)))
             (asetf (getf new-people-format :read)
                    (push (cons (car person)
                                (or (cdr person) nil))
                          it))
             (asetf (getf new-people-format :unread)
                    (push (cons (car person)
                                (or (cdr person) nil))
                          it))))
        (modify-db id :people new-people-format)
        (setf new-people-format (list :read (list) :unread (list)))))))

(defun all-inbox-items (&key (id *userid*))
  (sort (append (gethash id *person-conversation-index*)
                (gethash id *person-notification-index*)
                (remove-if-not #'result-gratitude-p
                               (gethash id *activity-person-index*)))
    #'> :key #'result-time))

(defun inbox-items (&key (page 0) (count 20))
  (let ((start (* page count))
        (items (all-inbox-items)))
    (html
      (iter (for i from 0 to (+ start count))
            (cond
              ((< i start)
               (setf items (cdr items)))
              ((and (>= i start) items)
               (let* ((item (car items))
                      (item-data (db (result-id item))))
                 (case (result-type item)
                   (:conversation
                     (let* ((id (result-id item))
                            (latest (latest-comment id))
                            (latest-seen (cdr (assoc *userid* (getf item-data :people))))
                            (comment-data (db latest))
                            (comments (length (gethash id *comment-index*)))
                            (people (remove *userid*
                                            (cons (getf comment-data :by)
                                                  (remove (getf comment-data :by)
                                                          (mapcar #'car (getf item-data :people)))))))
                       (str
                         (card
                           (html
                             (str (h3-timestamp (result-time item)))
                             (:p :class "people"
                               (cond
                                 ((eql (getf comment-data :by) *userid*)
                                  (str "↪ "))
                                 ((not (eql latest latest-seen))
                                  (str "• ")))

                               (if people
                                 (str (name-list people))
                                 (htm (:span :class "nobody" "Empty conversation"))))

                             (:p :class "text"
                               (:span :class "title"
                                 (:a :href (strcat "/conversations/" id) (str (ellipsis (getf item-data :subject) 30)))
                                 (when (> comments 1)
                                   (htm
                                     " (" (str comments) ")")))
                               " - "
                               (:a :href (strcat "/conversations/" id)
                                (str (ellipsis (getf comment-data :text))))))))))
                   (:reply
                     (let* ((id (result-id item))
                            (latest (latest-comment id))
                            (latest-seen (cdr (assoc *userid* (getf item-data :people))))
                            (comment-data (db latest))
                            (original-item (db (getf item-data :on)))
                            (deleted-type (getf item-data :deleted-item-type))
                            (original-item-type (or (getf original-item :type)
                                                    deleted-type))
                            (people (mapcar #'car (db id :people)))
                            (with (or (getf original-item :by)
                                      (first (remove *userid* people))))
                            (comments (length (gethash id *comment-index*)))
                            (text (if (and (= comments 1)
                                           deleted-type)
                                    (deleted-invalid-item-reply-text
                                      (db (second people) :name)
                                      (db (first people) :name)
                                      (case deleted-type
                                        (:offer "offer")
                                        (:request "request"))
                                      (getf comment-data :text))
                                    (getf comment-data :text))))
                       (str
                         (card
                           (html
                             (str (h3-timestamp (result-time item)))
                             (:p :class "people"
                               (cond
                                 ((eql (getf comment-data :by) *userid*)
                                  (str "↪ "))
                                 ((not (eql latest latest-seen))
                                  (str "• ")))

                               (if (eql (db id :by) *userid*)
                                 (htm
                                   "You replied to "
                                   (str (person-link with))
                                   "'s "
                                   (case original-item-type
                                     (:offer
                                      (htm (:a :href (strcat "/offers/" (getf item-data :on)) "offer")))
                                     (:request
                                      (htm (:a :href (strcat "/requests/" (getf item-data :on)) "request")))
                                     (t (case deleted-type
                                          (:offer (htm "offer"))
                                          (:request (htm "request"))
                                          (t (htm (:span :class "none" "deleted offer or request")))))))
                                 (htm
                                   (str (person-link (getf item-data :by)))
                                   " replied to your "
                                   (case original-item-type
                                     (:offer
                                      (htm (:a :href (strcat "/offers/" (getf item-data :on)) "offer")))
                                     (:request
                                      (htm (:a :href (strcat "/requests/" (getf item-data :on)) "request")))
                                     (t (case deleted-type
                                          (:offer (htm "offer"))
                                          (:request (htm "request"))
                                          (t (htm (:span :class "none" "deleted offer or request")))))))))

                             (:p :class "text"
                               (:span :class "title"
                                 (:a :href (strcat "/conversations/" id)
                                   (str (ellipsis (getf original-item :text) 30)))
                                 (when (> comments 1)
                                   (htm
                                     " (" (str comments) ") "))
                                 " - ")
                               (:a :href (strcat "/conversations/" id)
                                (str (ellipsis text)))))))))
                   (:contact-n
                     (str
                      (card
                        (html
                          (str (h3-timestamp (result-time item)))
                          (:p (str (person-link (getf item-data :subject))) " added you as a contact.")))))

                   (:gratitude
                     (unless (eql (getf item-data :author) *userid*)
                       (str
                        (card
                          (html
                            (str (h3-timestamp (result-time item)))
                            (:p (str (person-link (getf item-data :author))) " shared " (:a :href (strcat "/gratitude/" (result-id item)) "gratitude") " for you."))))))))
               (setf items (cdr items)))

              ((and (eql i start)
                    (not items))
               (htm
                 (:div :class "small card"
                   (:em "No results")))
               (finish)))

            (finally
              (when (or (> page 0) (cdr items))
                (htm
                  (:div :class "item"
                   (when (> page 0)
                     (htm
                       (:a :href (strcat "/messages?p=" (- page 1)) "< previous page")))
                   "&nbsp;"
                   (when (cdr items)
                     (htm
                       (:a :style "float: right;" :href (strcat "/messages?p=" (+ page 1)) "next page >")))))))))))

(defun get-messages ()
  (require-user
    (modify-db *userid* :last-checked-mail (get-universal-time))
    (send-metric* :checked-mailbox *userid*)
    (standard-page

      "Messages"

      (html
        (:div :class "card"
          (str (menu-horiz "actions"
                           (html (:a :href "/conversations/new" "start a new conversation")))))


        (str (inbox-items :page (if (scan +number-scanner+ (get-parameter "p"))
                                  (parse-integer (get-parameter "p"))
                                  0))))

      :selected "messages")))
