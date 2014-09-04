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

(defun migrate-to-new-transaction-format ()
  (dolist (id (hash-table-keys *db*))
    (let* ((data (db id))
           (type (getf data :type)))
      (when (eq type :reply)
        (modify-db id :type :transaction)))))

(defun create-transaction (&key on text action match-id pending-deletion (userid *userid*))
  (let* ((time (get-universal-time))
         (on-item (db on))
         (by (getf on-item :by))
         (participants (list userid by))
         (senders (mailbox-ids (list userid)))
         (bys (mailbox-ids (list by)))
         (sender-boxes (mapcar #'(lambda (mailbox)
                                   (cons mailbox :read))
                               senders))
         (by-boxes (mapcar #'(lambda (mailbox)
                                   (cons mailbox :unread))
                               bys))
         (people (append by-boxes sender-boxes))
         (people-ids (mapcar #'car (remove-duplicates (append senders bys))))
         (message-folders (list :inbox people-ids
                                :unread (remove userid people-ids)))
         (log (when action (list (list :time time :party (list userid) :action action))))
         (id (insert-db (if pending-deletion
                          (list :type :transaction
                                :on on
                                :deleted-item-text (getf on-item :text)
                                :deleted-item-details (getf on-item :details)
                                :deleted-item-title (getf on-item :title)
                                :deleted-item-type (getf on-item :type)
                                :by userid
                                :participants participants
                                :message-folders message-folders
                                :people people
                                :created time)
                          (list :type :transaction
                                :on on
                                :by userid
                                :participants participants
                                :message-folders message-folders
                                :people people
                                :log log
                                :created time)))))

      (when text (create-comment :on id
                                 :by (list userid)
                                 :text text
                                 :time (+ time 1) ; if there is both text/action, they need separate times for sorting in transaction log UI display
                                 ))

    (when match-id
      (case (getf on-item :type)
        (:offer (hide-matching-offer match-id on))
        (:request (hide-matching-offer on match-id))))

    id))

(defun transactions-pending-gratitude-for-account (account-id)
  (let* ((all-pending (gethash account-id *pending-gratitude-index*)))
    (mapcar #'cdr
            (append (getf all-pending :offers)
                    (getf all-pending :requests)))))

(defun transactions-pending-gratitude-for-user
  (&optional (userid *userid*)
   &aux (groups (mapcar #'car (groups-with-user-as-admin userid)))
        (transactions))
  (dolist (account (cons userid groups))
    (asetf transactions
           (append (transactions-pending-gratitude-for-account account)
                   it)))
  transactions)

(defun transaction-pending-gratitude-p
  (transaction-id &optional (data (db transaction-id))
                  &aux (pending-gratitude-p))

  (loop for event in (getf data :log)
        until (eq (getf event :action) :gratitude-posted)
        when (or (eq (getf event :action) :gave)
                 (eq (getf event :action) :received))
        do (setf pending-gratitude-p t))

  pending-gratitude-p)

(defun index-transaction
  (id
   data
   &aux (pending-gratitude-p (transaction-pending-gratitude-p id data)))

  (index-message id data)
      ;; see if there is a :given or :received action more recently than a 
      ;; :gratitude-posted

  (when pending-gratitude-p
    (let* ((item-id (getf data :on))
           (item (db item-id))
           (by (getf item :by))
           (result (when item ; prior to 6/3/2014 inventory items could be deleted
                     (inventory-item-result item-id
                                            :data item
                                            :by-id by))))

      (when result
        (with-locked-hash-table (*pending-gratitude-index*)
          (case (getf item :type)
            (:offer
              (push (cons result id)
                    (getf (gethash (getf data :by) *pending-gratitude-index*)
                          :offers)))
            (:request
              (push (cons result id)
                    (getf (gethash by *pending-gratitude-index*)
                          :requests)))))))))

(defun transaction-history
  (transaction-id
   on-type
   on-url
   inventory-by
   latest-seen
   &optional (transaction (db transaction-id))
   &aux (actions (getf transaction :log))
        (comments (gethash transaction-id *comment-index*))
        (history))

  (dolist (action actions)
    (when (getf action :action)
      (sort (push action history) #'> :key #'(lambda (entry)
                                               (getf entry :time)))))

  (dolist (comment-id comments)
    (let* ((data (db comment-id))
           (participants (getf transaction :participants))
           (by (car (getf data :by)))
           (for (cdr (getf data :by)))
           (bydata (db by))
           (text (if (and (equal comment-id (first comments))
                          (getf transaction :deleted-item-type))
                   (deleted-invalid-item-reply-text
                     (db (car (remove by participants)) :name)
                     (getf bydata :name)
                     (case (getf transaction :deleted-item-type)
                       (:offer "offer")
                       (:request "request"))
                     (getf data :text))
                   (getf data :text))))

      (sort (push (list :time (getf data :created)
                        :id comment-id
                        :data data
                        :by by
                        :by-name (getf bydata :name)
                        :for for
                        :for-name (db for :name)
                        :text text)
                  history)
            #'>
            :key #'(lambda (entry) (getf entry :time)))))

  (html
    (dolist (event history)
      (acond
       ((getf event :action)
        (str (transaction-action-html event
                                      on-type
                                      on-url
                                      (if (eql inventory-by *userid*)
                                        "you"
                                        (person-link inventory-by))
                                      (if (eql (getf transaction :by) *userid*)
                                        "you"
                                        (person-link (getf transaction :by))))))

       ((getf event :text)
        (str (conversation-comment-html
                (getf event :data)
                (getf event :by)
                (getf event :by-name)
                (getf event :for)
                (getf event :for-name)
                (getf event :text)
                (when (>= (or latest-seen 0)
                          (getf event :id))))))))))

(defun transaction-other-party
  (transaction-id
   &optional (userid *userid*)
   &aux (transaction (db transaction-id))
    )
  )
(defun transaction-action-text
  (log-event
   on-type
   on-url
   inventory-by-name
   transaction-initiator-name
   &aux (action-party (car (getf log-event :party)))
        (self (eql action-party *userid*)))
  (strcat*
    (if self "You" (person-link action-party))
    (awhen (cdr (getf log-event :party))
      (strcat* " (on behalf of " (group-link it) ")" ))
    (case on-type
      (:offer
        (case (getf log-event :action)
          (:requested
            (strcat " requested to recieve this "
                on-url
                " from "
                inventory-by-name) )
          (:offered
            (strcat " agreed to share this " on-url " with "
                transaction-initiator-name))
          (:declined
            (strcat* " no longer wish" (unless self "es")
                     " to receive this " on-url " from "
                    inventory-by-name))
          (:gave
            (strcat " shared this " on-url " with "
                transaction-initiator-name))
          (:received
            (strcat " received this "
                    on-url
                    " from "
                inventory-by-name))
          (:disputed
            (strcat " disputed having received this " on-url " from "
                inventory-by-name))
          (:gratitude-posted
            (strcat " posted a statement of gratitude about "
                    inventory-by-name
                    " for this "
                    on-url))))
      (:request
        (case (getf log-event :action)
          (:requested
            (strcat* " want" (unless self "s")
                     " to receive what "
                     transaction-initiator-name
                     (if (string= transaction-initiator-name "you")
                       " are" " is")
                     " offering") )
          (:offered
            (strcat " agreed to fulfill this " on-url " from "
                inventory-by-name))
          (:declined
            (strcat* " no longer wish" (unless self "es")
                     " to receive this " on-url " from "
                     transaction-initiator-name))
          (:gave
            (strcat " fulfilled this " on-url " from "
                inventory-by-name))
          (:received
            (strcat " received this " on-url " from "
                transaction-initiator-name))
          (:disputed
            (strcat " disputed having received this " on-url " from "
                transaction-initiator-name))
          (:gratitude-posted
            (strcat " posted a statement of gratitude about "
                    transaction-initiator-name
                    " for this "
                    on-url)))))
    "."
    ))

(defun transaction-action-html
  (log-event
   on-type
   on-url
   inventory-by-name
   transaction-initiator-name)

  (case (getf log-event :action)
    (:gratitude-posted
      (gratitude-activity-item (gethash (getf log-event :comment) *db-results*)
                               :show-on-item nil))
    (t
      (card
        (html
          (str (h3-timestamp (getf log-event :time)))
          (:p
            (:strong
              (str (transaction-action-text log-event
                                            on-type
                                            on-url
                                            inventory-by-name
                                            transaction-initiator-name
                                            )))))))))

(defun transaction-comments (transaction-id latest-seen)
  (html
    (dolist (comment-id (gethash transaction-id *comment-index*))
      (let* ((data (db comment-id))
             (by (car (getf data :by)))
             (for (cdr (getf data :by)))
             (text (getf data :text)))

        (when data
           (str (conversation-comment-html data
                                          by
                                          (db by :name)
                                          for
                                          (db for :name)
                                          text
                                          (when (>= (or latest-seen 0)
                                                    comment-id)))))))))

(defun transaction-comment-input (transaction-id &key error)
  (html
    (:div :class "item" :id "reply"
      (:h4 "post a reply")
      (:form :method "post" :action (strcat "/transactions/" transaction-id)
        (:textarea :cols "150" :rows "4" :name "text")
        (:div :class (when (eq error :no-reply-type)
                       "error-border"))
        (:button :class "cancel" :type "submit" :name "cancel" "Cancel")
        (:button :class "yes" :type "submit" :name "submit" "Send")))))

(defun transaction-buttons-html
  (transaction-options
   other-party-name
   on-type
   on-url
   url)
  (html
    (:div :class "trans-options" "Options:")
    (:div :class "transaction-options item"

      (when (find "post-gratitude" transaction-options :test #'string=)
        (htm
          (:div :class "transaction-option"
            (:a :href (url-compose url "post-gratitude" "t")
              (str (icon "heart-person"))
              (str (s+ "I have gratitude to share about "
                       other-party-name
                       " for this gift."))))))

      (flet ((transaction-button
               (status icon request-text offer-text &optional (value status) (name "transaction-action"))
               (when (find status transaction-options :test #'string=)
                 (html
                   (:div :class "transaction-option"
                    (:button :type "submit"
                     :class "simple-link"
                     :name name
                     :value value
                     (str icon)
                     (str (if (eq on-type :request)
                            request-text offer-text))))))))

        (htm
          (:form :method "post" :action url

            (str (transaction-button
                   "will-give"
                   (icon "offers")
                   (s+ "I want to fulfill " other-party-name "'s request.")
                   (s+ "I want to share this offering with " other-party-name ".")))

            (str (transaction-button
                   "will-give-again"
                   (icon "offers")
                   (s+ "I want to give this to " other-party-name "again.")
                   (s+ "I want to share this offering with " other-party-name " again.")
                   "will-give"))

            (str (transaction-button
                   "withhold"
                   (icon "withhold")
                   (s+ "I can't fulfill " other-party-name "'s request at this time.")
                   (s+ "I can't share this offer with " other-party-name " at this time.")))

            (str (transaction-button
                   "already-given"
                   (icon "gift")
                   (s+ "I have fulfilled " other-party-name "'s request.")
                   (s+ "I have shared this offer with " other-party-name ".")))

            (str (transaction-button
                   "already-given-again"
                   (icon "gift")
                   (s+ "I have given this to " other-party-name "again.")
                   (s+ "I have shared this offer with " other-party-name " again.")
                   "already-given"))

            (str (transaction-button
                   "want"
                   (icon "requests")
                   (s+ "I want to recieve what " other-party-name " is offering me.")
                   (s+ "I want to recieve this offer from " other-party-name ".")))

            (str (transaction-button
                   "want-again"
                   (icon "requests")
                   (s+ "I want to recieve this from " other-party-name " again.")
                   (s+ "I want to recieve this offer from " other-party-name " again.")
                   "want"))

            (str (transaction-button
                   "already-received"
                   (icon "gift")
                   (s+ "I have received what " other-party-name " has offered me.")
                   (s+ "I have received this offer from " other-party-name ".")))

            (str (transaction-button
                   "already-received-again"
                   (icon "gift")
                   (s+ other-party-name " has given this to me again. ")
                   (s+ other-party-name " has given this to me again. ")
                   "already-received"))

            (str (transaction-button
                   "decline"
                   (icon "decline")
                   (s+ "I don't want what " other-party-name " has offered me.")
                   (s+ "I no longer want this offer from " other-party-name ".")))

            (str (transaction-button
                   "dispute"
                   (icon "caution")
                   (s+ "I have <strong>not</strong> yet received what "
                       other-party-name " has offered me.")
                   (s+ "I have <strong>not</strong> yet received this offer from " other-party-name ".")))))

        (when (find "deactivate" transaction-options :test #'string=)
          (htm
            (:form :method "post" :action on-url
             (:input :type "hidden" :name "next" :value url)
             (str (transaction-button
                    "deactivate"
                    (icon (if (eql on-type :offer)
                            "empty-giving-hand"
                            "empty-receiving-hand"))
                    (s+ "I am no longer requesting this item.  Please deactivate it.")
                    (s+ "I am no longer offering this item.  Please deactivate it.")
                    t
                    "deactivate"))))))

       (:div :class "transaction-option"
         (:a :href (url-compose url "add-comment" "t")
           (str (icon "comment"))
           (str (s+ "I have a question or comment for " other-party-name ".")))))))

(defun transaction-html
  (transaction-id
   on-item
   role
   history-html
   form-elements-html
   &key (data (db transaction-id))
        deleted-type
        on-type
        other-party-link
   &aux (inventory-url (case on-type
                         (:offer (strcat "/offers/" (getf data :on)))
                         (:request (strcat "/requests/" (getf data :on)))))
        (inventory-link (case on-type
                          (:offer
                            (html (:a :href inventory-url "offer")))
                          (:request
                            (html (:a :href inventory-url "request")))
                          (t (case deleted-type
                               (:offer "offer")
                               (:request "request")
                               (t (html
                                    (:span :class "none" "deleted offer or request")))))))
        (offer-p (eql on-type :offer))
        (status (getf (car (last (getf data :log))) :action)))

  (standard-page
    "Transaction"
    (html
      (str (menu-horiz "actions"
                       (html (:a :href "/messages" "back to messages"))
                       (html (:a :href (url-compose (strcat "/transactions/"
                                                            transaction-id)
                                                    "add-comment" "t" )
                              "reply"))))

       (if (eql (getf data :by) *userid*)
         (htm
           (:p
           "You replied to "
           (str other-party-link)
           "'s "
           (str inventory-link)
           ":"))
         (htm
           (:p
             (str other-party-link)
             " has responded to "
             (cond
               ((eq (getf on-item :by) *userid*)
                (str "your "))
               ((not (getf on-item :by))
                (str "a ")) ; for old inventory items that got deleted
               (t (str (s+ (db (getf on-item :by) :name) "'s "))))
             (str inventory-link)
             (when on-item (htm ":")))))

       (when on-item
         (htm (:blockquote :class "review-text"
                (awhen (getf on-item :title)
                  (htm
                    (:strong (str it))
                    (:br)
                    (:br)))
                (str (ellipsis (or (getf on-item :details)
                                   (getf data :deleted-item-text))
                               :see-more inventory-url)))))

      (when  (or (eq status :offered)
                 (eq status :requested)
                 (eq status :gave)
                 (eq status :received)
                 (eq status :disputed)
                 (eq status :gratitude-posted))
        (htm
          (:table :class "transaction-progress"
            (:tr
              (:td :class "progress-header" :colspan "4" (:strong  "Transaction Progress:")))
            (:tr :class "steps"
              (:td :class "done"
                (:div "1. ")
                (:div (str (if offer-p "Requested" "Offered"))))
              (:td :class (when (or (and offer-p (eq status :offered))
                                    (and (not offer-p) (eq status :requested))
                                    (eq status :gave)
                                    (eq status :received)
                                    (eq status :gratitude-posted))
                            "done")
                (:div "2. ")
                (:div (str (if offer-p "Committed" "Accepted"))))
              (:td :class (when (or (eq status :gratitude-posted)
                                    (eq status :gave)
                                    (eq status :received))
                            "done")
                (:div "3. ")
                (:div (str (case role (:giver "Given") (:receiver "Received")))))
              (:td :class (when (eq status :gratitude-posted)
                            "done")
                (:div "4. ")
                (:div :class "gratitude-step" "Gratitude Posted " (when (eq status :gratitude-posted) (str (icon "white-checkmark")))))))))

      (str form-elements-html)
      (str history-html))

    :selected "messages"))

(defun transaction-options-for-user
  (transaction-id
   &key (userid *userid*)
        (transaction (db transaction-id))
   &aux (transaction-mailboxes (mapcar #'car (getf transaction :people)))
        (log (getf transaction :log))
        (inventory-item (db (getf transaction :on)))
        (inventory-type (getf inventory-item :type))
        (inventory-by (getf inventory-item :by))
        (inventory-by-self-p (or (eql userid inventory-by)
                                 (eql inventory-by
                                      (cdr (assoc userid transaction-mailboxes)))))
        (role (case inventory-type
                (:offer (if inventory-by-self-p :giver :receiver))
                (:request (if inventory-by-self-p :receiver :giver ))))
        (representing (if (or (eql userid inventory-by)
                              (eql userid (getf transaction :by)))
                        userid
                        (cdr (assoc userid transaction-mailboxes))))
        (gratitude-expressed-p (find :gratitude-posted
                                     log
                                     :key #'(lambda (event)
                                              (getf event :action))
                                     :from-end t))
        (current-event (find userid
                             log
                             :test #'eql
                             :key #'(lambda (event)
                                       (car (getf event :party)))
                             :from-end t))
        (other-party-event (find-if-not
                             #'(lambda (event)
                                 (if representing
                                   (eql representing (cdr (getf event :party)))
                                   (eql userid (car (getf event :party)))))
                             log
                             :from-end t))
        (options ()))

  "Returns (1) a list of actions the user can take on a given transaction id and (2) the entity the user is representing (i.e. *userid* or a groupid)"

  (setf options
        (case role
          (:receiver
             (case (getf current-event :action)
               (:requested
                 (case (getf other-party-event :action)
                   (:gave '("post-gratitude" "dispute"))
                   (t '("decline" "already-received"))))
               (:declined '("want" "already-received"))
               (:disputed '("already-received"))
               (:received '("post-gratitude"))
               (t (case (getf other-party-event :action)
                    (:gave '("already-received" "dispute"))
                    (t '("want" "already-received"))))))
          (:giver
            (case (getf current-event :action)
              (:offered
                (case (getf other-party-event :action)
                  (:received nil)
                  (t '("withheld" "already-given"))))
              (:gave
                (when (and (eql (getf other-party-event :action)
                                :gratitude-posted)
                           (getf inventory-item :active))
                  '("will-give" "already-given")))
              (t '("will-give" "already-given"))))))

  (when (and inventory-item inventory-by-self-p)
    (case role
      (:giver
        (if (getf inventory-item :active)
          (push "deactivate" options)
          (progn (push "reactivate" options)
                 (remove "will-give" options :test #'string=))))
      (:receiver
        (if (getf inventory-item :active)
          (unless (or (find "decline" options :test #'string=)
                      (and (eql (getf other-party-event :action)
                                 :gave)
                           (find transaction-id
                                 (getf (gethash representing
                                                *pending-gratitude-index*)
                                       (if (eq inventory-type :request)
                                         :requests
                                         :offers))
                                 :key #'cdr)))
            (push "deactivate" options))
          (progn (push "reactivate" options)
                 (remove "want" options :test #'string=))))))

  (when gratitude-expressed-p
    (flet ((subst-opt (new old)
             (when (find old options :test #'string=)
               (asetf options (cons new (remove old it :test #'string=))))))
      (subst-opt "already-received-again" "already-received")
      (subst-opt "already-given-again" "already-given")
      (asetf options (remove "want"
                       (remove "will-give" it :test #'string=) :test #'string=))))

  (values options
          representing
          role
          current-event
          other-party-event))

(defun get-transaction (id)
"when called, (modify-db conversation-id :people '((userid . this-comment-id) (other-user-id . whatever)))"
  (require-user
    (setf id (parse-integer id))
    (let* ((message (gethash id *db-messages*))
           (people (message-people message))
           (valid-mailboxes (loop for person in people
                                  when (eql *userid* (caar person))
                                  collect person))
           (add-comment (string= (get-parameter "add-comment") "t"))
           (type (message-type message)))

      (if (eq type :transaction)
        (if valid-mailboxes
          (let* ((transaction (db id))
                 (url (strcat "/transactions/" id))
                 (person (assoc-assoc *userid* people))
                 (latest-comment (getf transaction :latest-comment))
                 (latest-seen (or (when (numberp (cdr person))
                                    (cdr person))
                                  latest-comment))
                 (on-id (getf transaction :on))
                 (on-item (db on-id))
                 (inventory-by (getf on-item :by))
                 (transaction-options)
                 (speaking-for)
                 (other-party)
                 (other-party-name)
                 (user-role)
                 (post-gratitude-p (get-parameter-string "post-gratitude"))
                 (with (remove *userid* (getf transaction :participants)))
                 (deleted-type (getf transaction :deleted-item-type))
                 (on-type (getf on-item :type))
                 (on-type-string (case on-type
                           (:offer "offer")
                           (:request "request")))
                 (on-url (strcat "/" on-type-string "s/" on-id))
                 (on-link (html (:a :href on-url (str on-type-string)))))

            (multiple-value-bind (options for role)
              (transaction-options-for-user id :transaction transaction)
              (setf transaction-options options)
              (setf speaking-for for)
              (setf user-role role))

            (setf other-party (car (remove speaking-for with)))
            (setf other-party-name (db other-party :name))

            (prog1
              (transaction-html id
                                on-item
                                user-role
                                (transaction-history id
                                                     on-type
                                                     on-link
                                                     inventory-by
                                                     latest-seen
                                                     transaction)
                                (cond
                                  (post-gratitude-p
                                    (simple-gratitude-compose
                                      other-party
                                      :next url
                                      :transaction-id id
                                      :post-as speaking-for
                                      :on-id on-id
                                      :submit-name "create"
                                      :button-location :bottom))
                                  (add-comment
                                    (transaction-comment-input id))
                                  (t (transaction-buttons-html
                                       transaction-options
                                       other-party-name
                                       on-type
                                       on-url
                                       url)))
                                :data transaction
                                :other-party-link (person-link other-party)
                                :deleted-type deleted-type
                                :on-type on-type)

              ; get most recent comment seen
              ; get comments for
              (when (or (not (eql (message-latest-comment message)
                                  (cdr (assoc-assoc *userid*
                                                    (message-people message)))))
                        (member *userid*
                                (getf (message-folders message) :unread)))
                (update-folder-data message :read :last-read-comment (message-latest-comment message)))))

          (permission-denied))
      (not-found)))))


(defun post-transaction (id)
  (require-active-user
    (setf id (parse-integer id))
    (let ((transaction (db id)))
      (if (eq (getf transaction :type) :transaction)
        (let* ((people (getf transaction :people))
               (mailbox (assoc-assoc *userid* people))
               (party (car mailbox))
               (action-string (post-parameter-string "transaction-action"))
               (action)
               (inventory-item (db (getf transaction :on)))
               (url (strcat "/transactions/" id)))
          (setf action
                (cond
                  ((string= action-string "want")
                   :requested)
                  ((string= action-string "will-give")
                   :offered)
                  ((string= action-string "decline")
                   :declined)
                  ((string= action-string "withhold")
                   :withheld)
                  ((string= action-string "already-given")
                   :gave)
                  ((string= action-string "already-received")
                   :received)
                  ((string= action-string "dispute")
                   :disputed)))
          (if party
            (flet ((modify-log (new-action)
                     (amodify-db id :log (append
                                          it
                                          (list
                                            (list :time (get-universal-time)
                                                  :party party
                                                  :action new-action))))
                     (see-other url)))
              (cond
                ((post-parameter "cancel")
                 (see-other url))

                ((post-parameter "text")
                 (flash "Your message has been sent.")
                 (contact-opt-out-flash (mapcar #'caar people))
                 (let* ((time (get-universal-time))
                        (new-comment-id (create-comment :on id
                                                        :text (post-parameter "text")
                                                        :time time
                                                        :by party)))
                   (send-metric* :message-sent new-comment-id))
                 (see-other url))

                ((eq action :declined)
                 (confirm-action
                   "Decline Gift"
                   (strcat "Please confirm that you no longer wish to receive this gift from "
                           (case (getf inventory-item :type)
                             (:offer (db (getf inventory-item :by) :name))
                             (:request (db (getf transaction :by) :name)))
                           ":")
                   :url url
                   :next-url url
                   :details (or (getf inventory-item :title)
                                (getf inventory-item :details))
                   :post-parameter "confirm-decline"))

                ((post-parameter "confirm-decline")
                  (modify-log :declined))

                ((eq action :withheld)
                 (confirm-action
                   "Withhold Gift"
                   (strcat "Please confirm that you no longer wish to give this gift to "
                           (case (getf inventory-item :type)
                             (:request (db (getf inventory-item :by) :name))
                             (:offer (db (getf transaction :by) :name)))
                           ":")
                   :url url
                   :next-url url
                   :details (or (getf inventory-item :title)
                                (getf inventory-item :details))
                   :post-parameter "confirm-withhold"))

                ((post-parameter "confirm-withhold")
                  (modify-log :withheld))

                (action
                  (modify-log action))))

            (permission-denied)))

      (not-found)))))
