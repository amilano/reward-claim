(module reward-claim GOV

(use free.util-fungible)
(use free.util-time)

; Capabilities
(defcap GOV ()
  (enforce-keyset "CLAIM_NS.governance" ))

(defcap OPS ()
  (enforce-keyset "CLAIM_NS.ops"))

(defcap USER-PROOF (userId:string questId:string)
  (with-read users (user-key userId questId)
    { 'guard := g }
  (enforce-keyset g)))

(defcap CLAIMABLE (userId:string questId:string)
  @doc "Tests the guard through USER-PROOF"
  (compose-capability (USER-PROOF userId questId))
  (compose-capability (CLAIM)))

; Event Trackers

(defcap SET-REWARD (userId:string questId:string amount:decimal)
  @event true)

(defcap CLAIM-INFO (userId:string questId:string amount:decimal)
  @event true)

(defcap CREATE-QUEST (questId:string amount:decimal startDate:time endDate:time winners:integer)
  @event true)

; Schemas

(defschema quest-schema
  @doc "Key value is hased questId"
  startDate:time
  endDate:time
  amount:decimal
  winners:integer)

(defschema user-schema
  @doc "Key value is userId:questId"
  reward:decimal
  claimed:bool
  guard:guard)

(defschema general-stats-schema
  @doc "Key value is userId"
  totalClaims:integer
  totalClaimed:decimal
  lastClaim:time)

(defschema bulk-schema
  @doc "Used to check object format is correct"
  userId:string
  amount:decimal
  guard:guard)

(deftable quests:{quest-schema})
(deftable users:{user-schema})
(deftable userstats:{general-stats-schema})

; Treasury

(defun get-treasury ()
  @doc "Returns the treasury address"
 CLAIM-ACCOUNT)

(defcap CLAIM () true)
(defconst CLAIM-GUARD (create-capability-guard (CLAIM)))
(defconst CLAIM-ACCOUNT (create-principal CLAIM-GUARD))

; Initiator Functions

(defun create-quest:string (questId:string amount:decimal startDate:time endDate:time winners:integer)
  @doc "Creates a quest"

  ;; contains enforcement for all inputs, tx will fail if any of these are not met
  (validate-quest amount startDate endDate winners)
  (validate-string questId STRLENGTH)

  (with-capability (OPS)
    (insert quests questId { "amount": amount,
            "startDate": startDate,
            "endDate": endDate,
            "winners": winners }))
    (emit-event (CREATE-QUEST questId amount startDate endDate winners))
    (format "Quest {} created" [questId]))

; Interactive Functions

(defun set-rewards-bulk:string (questId:string reward-entries:[object{bulk-schema}])
  @doc "Qualifies rewards to multiple users for a quest by calling set-rewards"
  (map
    (lambda (entry:object{bulk-schema})
      (set-rewards
        questId
        (at 'userId entry)
        (at 'guard entry)
        (at 'amount entry)))
    reward-entries)
  "Bulk rewards processed")

(defun set-rewards:bool (questId:string userId:string guard:guard amount:decimal)
  @doc "Qualifies rewards to a user"

  ;; Validates the quest entries
  (validate-set-rewards amount questId)
  (enforce-valid-account userId)

  (with-read quests questId
    { 'startDate := sd, 'endDate := ed, 'amount := a, 'winners := w }

    (with-capability (OPS)
      (update quests questId { 'amount: (- a amount), 'winners: (- w 1) }))

      (insert users (user-key userId questId) { 'reward: amount, 'claimed: false, 'guard: guard })
      (emit-event (SET-REWARD userId questId amount))))

; Internal Functions

(defun claim:string (userId:string questId:string)
  @doc "Claims rewards for a user"

  ;; Validates if there is enough reward to pay out
  (validate-winning userId questId)

  (with-read users (user-key userId questId) {'reward:= r, 'guard:= g }

  (with-capability (CLAIMABLE userId questId)
    (install-capability (coin.TRANSFER CLAIM-ACCOUNT userId r))
    (coin.transfer-create CLAIM-ACCOUNT userId g r)
    (increment-user-stats userId questId r))

    (update users (user-key userId questId) { 'reward: 0.0, 'claimed: true })

    (emit-event (CLAIM-INFO userId questId r))
    (format "{} claimed {} rewards from quest {}" [userId r questId])))

(defun increment-user-stats:string (userId:string questId:string reward:decimal)
  @doc "Increments the user stats"
  (require-capability (CLAIMABLE userId questId))

  (with-default-read userstats userId
  { 'totalClaims: 0, 'totalClaimed: 0.0, 'lastClaim: EPOCH }
  { 'totalClaims := tc, 'totalClaimed := tcl, 'lastClaim := lc }
    (write userstats userId { 'totalClaims: (+ tc 1), 'totalClaimed: (+ tcl reward), 'lastClaim: (curr-time) })))


(defun admin-withdrawal:string (questId:string receiver:string)
  @doc "Allows the admin to withdraw funds from the escrow based on questId"
  (with-read quests questId { 'amount := a }
    (enforce (> a 0.0) "No funds to withdraw")

    (let ((t:decimal (treasury-balance)))
    (enforce (>= t a) "Not enough funds in treasury"))

    (with-capability (OPS)
      (update quests questId { 'amount: 0.0 }))

        (with-capability (CLAIM)
          (install-capability (coin.TRANSFER CLAIM-ACCOUNT receiver a))
          (coin.transfer CLAIM-ACCOUNT receiver a))))

; Constants

(defconst STRLENGTH:integer 3)

; Helper Functions

(defun get-user-claim:decimal (userId:string questId:string)
  @doc "Returns the user claim"
  (at 'reward (read users (user-key userId questId))))

(defun get-user-stats:object{general-stats-schema} (userId:string)
  @doc "Returns the user stats"
  (read userstats userId))

(defun get-quest:object{quest-schema} (questId:string)
  @doc "Returns the quest details"
  (read quests questId))

(defun user-key:string (userId:string questId:string)
  @doc "Returns the user key"
  (format "{}:{}" [userId questId]))

(defun treasury-balance:decimal ()
  @doc "Returns the treasury balance"
  (coin.get-balance CLAIM-ACCOUNT))

(defun curr-time:time ()
  @doc "Returns current chain's block-time"
  (at 'block-time (chain-data)))


; Validation Functions

(defun validate-winning:bool (userId:string questId:string)
  @doc "Validates that the reward is not empty"
  (with-read users (user-key userId questId) { 'reward:= r, 'claimed:= c }
    (enforce (not c) "Reward already claimed")
    (enforce (> r 0.0) "No rewards to claim")
    (let ((t:decimal (treasury-balance)))
    (enforce (<= r t) "Not enough funds in treasury"))))

(defun validate-quest:bool (amount:decimal startDate:time endDate:time winners:integer)
  @doc "Validates the create quest parameters"
  (enforce (> amount 0.0) "Amount must be greater than 0.0")
  (enforce (> winners 0) "Winners must be greater than 0")
  (enforce (> endDate startDate) "End date must be greater than start date")
  (enforce (>= startDate (curr-time) ) "Start date must be greater than or equal to current time"))

; ed = endDate, a = quest amount, amount = payout amount, w = winners
(defun validate-set-rewards:bool (amount:decimal questId:string)
  @doc "Validates the quest entries"
  (enforce (> amount 0.0) "Amount must be greater than 0")

  (with-read quests questId
    { 'startDate := sd, 'endDate := ed, 'amount := a, 'winners := w }

  (enforce (is-past ed) "Quest end date must be complete before rewards are distributed")
  (enforce (<= amount a) "Amount must be less than or equal to quest amount")

  (let ((t:decimal (treasury-balance)))
    (enforce (>= t amount) "Not enough funds in treasury"))
  (enforce (> w 0) "No winners left")))

(defun validate-string:bool (str:string min-length:integer)
  @doc "Validates that a string is not empty and meets minimum length"
  (enforce (!= str "") "String cannot be empty")
  (enforce (>= (length str) min-length)
    (format "String must be at least {} characters" [min-length])))

)
(coin.create-account CLAIM-ACCOUNT CLAIM-GUARD)
(create-table users)
(create-table quests)
(create-table userstats)
