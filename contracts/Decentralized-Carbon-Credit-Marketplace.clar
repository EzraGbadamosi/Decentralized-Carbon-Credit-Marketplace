(define-non-fungible-token carbon-credit uint)

(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_AUTHORIZED (err u100))
(define-constant ERR_NOT_FOUND (err u101))
(define-constant ERR_INVALID_AMOUNT (err u102))
(define-constant ERR_NOT_VERIFIED (err u103))
(define-constant ERR_ALREADY_EXISTS (err u104))
(define-constant ERR_INSUFFICIENT_FUNDS (err u105))
(define-constant ERR_INVALID_PRICE (err u106))
(define-constant ERR_ALREADY_RETIRED (err u107))

(define-data-var credit-id-nonce uint u0)
(define-data-var project-id-nonce uint u0)
(define-data-var retirement-id-nonce uint u0)

(define-map projects
  { project-id: uint }
  {
    creator: principal,
    name: (string-ascii 50),
    description: (string-ascii 200),
    carbon-amount: uint,
    approved: bool,
    completed: bool,
    verification-deadline: uint
  }
)

(define-map carbon-credits
  { credit-id: uint }
  {
    project-id: uint,
    creator: principal,
    carbon-amount: uint,
    verified: bool,
    verifier: (optional principal),
    created-at: uint,
    price: uint,
    for-sale: bool
  }
)

(define-map auditors
  { auditor: principal }
  { approved: bool }
)

(define-map project-votes
  { project-id: uint, voter: principal }
  { vote: bool }
)

(define-map project-vote-counts
  { project-id: uint }
  { yes-votes: uint, no-votes: uint }
)

(define-map escrow-funds
  { project-id: uint }
  { amount: uint, depositor: principal }
)

(define-map marketplace-listings
  { credit-id: uint }
  { seller: principal, price: uint, active: bool }
)

(define-map retired-credits
  { retirement-id: uint }
  {
    credit-id: uint,
    original-owner: principal,
    retired-by: principal,
    carbon-amount: uint,
    retirement-reason: (string-ascii 100),
    retired-at: uint
  }
)

(define-map credit-retirement-status
  { credit-id: uint }
  { 
    retired: bool,
    retirement-id: (optional uint)
  }
)

(define-public (register-auditor (auditor principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (map-set auditors { auditor: auditor } { approved: true })
    (ok true)
  )
)

(define-public (create-project (name (string-ascii 50)) (description (string-ascii 200)) (carbon-amount uint))
  (let
    ((project-id (+ (var-get project-id-nonce) u1)))
    (begin
      (var-set project-id-nonce project-id)
      (map-set projects
        { project-id: project-id }
        {
          creator: tx-sender,
          name: name,
          description: description,
          carbon-amount: carbon-amount,
          approved: false,
          completed: false,
          verification-deadline: (+ stacks-block-height u1000)
        }
      )
      (map-set project-vote-counts
        { project-id: project-id }
        { yes-votes: u0, no-votes: u0 }
      )
      (ok project-id)
    )
  )
)

(define-public (vote-on-project (project-id uint) (vote bool))
  (let
    ((existing-vote (map-get? project-votes { project-id: project-id, voter: tx-sender }))
     (vote-counts (unwrap! (map-get? project-vote-counts { project-id: project-id }) ERR_NOT_FOUND)))
    (begin
      (asserts! (is-none existing-vote) ERR_ALREADY_EXISTS)
      (map-set project-votes { project-id: project-id, voter: tx-sender } { vote: vote })
      (if vote
        (map-set project-vote-counts
          { project-id: project-id }
          { yes-votes: (+ (get yes-votes vote-counts) u1), no-votes: (get no-votes vote-counts) }
        )
        (map-set project-vote-counts
          { project-id: project-id }
          { yes-votes: (get yes-votes vote-counts), no-votes: (+ (get no-votes vote-counts) u1) }
        )
      )
      (ok true)
    )
  )
)

(define-public (approve-project (project-id uint))
  (let
    ((project (unwrap! (map-get? projects { project-id: project-id }) ERR_NOT_FOUND))
     (vote-counts (unwrap! (map-get? project-vote-counts { project-id: project-id }) ERR_NOT_FOUND)))
    (begin
      (asserts! (> (get yes-votes vote-counts) (get no-votes vote-counts)) ERR_NOT_AUTHORIZED)
      (asserts! (>= (get yes-votes vote-counts) u3) ERR_NOT_AUTHORIZED)
      (map-set projects
        { project-id: project-id }
        (merge project { approved: true })
      )
      (ok true)
    )
  )
)

(define-public (deposit-escrow (project-id uint))
  (let
    ((project (unwrap! (map-get? projects { project-id: project-id }) ERR_NOT_FOUND)))
    (begin
      (asserts! (get approved project) ERR_NOT_AUTHORIZED)
      (asserts! (> stx-liquid-supply u0) ERR_INSUFFICIENT_FUNDS)
      (try! (stx-transfer? u1000000 tx-sender (as-contract tx-sender)))
      (map-set escrow-funds
        { project-id: project-id }
        { amount: u1000000, depositor: tx-sender }
      )
      (ok true)
    )
  )
)

(define-public (mint-carbon-credit (project-id uint) (carbon-amount uint) (price uint))
  (let
    ((project (unwrap! (map-get? projects { project-id: project-id }) ERR_NOT_FOUND))
     (credit-id (+ (var-get credit-id-nonce) u1)))
    (begin
      (asserts! (is-eq tx-sender (get creator project)) ERR_NOT_AUTHORIZED)
      (asserts! (get approved project) ERR_NOT_AUTHORIZED)
      (asserts! (> carbon-amount u0) ERR_INVALID_AMOUNT)
      (asserts! (> price u0) ERR_INVALID_PRICE)
      (var-set credit-id-nonce credit-id)
      (try! (nft-mint? carbon-credit credit-id tx-sender))
      (map-set carbon-credits
        { credit-id: credit-id }
        {
          project-id: project-id,
          creator: tx-sender,
          carbon-amount: carbon-amount,
          verified: false,
          verifier: none,
          created-at: stacks-block-height,
          price: price,
          for-sale: false
        }
      )
      (map-set credit-retirement-status
        { credit-id: credit-id }
        { retired: false, retirement-id: none }
      )
      (ok credit-id)
    )
  )
)

(define-public (verify-carbon-credit (credit-id uint))
  (let
    ((credit (unwrap! (map-get? carbon-credits { credit-id: credit-id }) ERR_NOT_FOUND))
     (auditor-status (unwrap! (map-get? auditors { auditor: tx-sender }) ERR_NOT_AUTHORIZED)))
    (begin
      (asserts! (get approved auditor-status) ERR_NOT_AUTHORIZED)
      (asserts! (not (get verified credit)) ERR_ALREADY_EXISTS)
      (map-set carbon-credits
        { credit-id: credit-id }
        (merge credit { verified: true, verifier: (some tx-sender) })
      )
      (ok true)
    )
  )
)

(define-public (release-escrow (project-id uint))
  (let
    ((project (unwrap! (map-get? projects { project-id: project-id }) ERR_NOT_FOUND))
     (escrow (unwrap! (map-get? escrow-funds { project-id: project-id }) ERR_NOT_FOUND))
     (auditor-status (unwrap! (map-get? auditors { auditor: tx-sender }) ERR_NOT_AUTHORIZED)))
    (begin
      (asserts! (get approved auditor-status) ERR_NOT_AUTHORIZED)
      (asserts! (get approved project) ERR_NOT_AUTHORIZED)
      (try! (as-contract (stx-transfer? (get amount escrow) tx-sender (get creator project))))
      (map-set projects
        { project-id: project-id }
        (merge project { completed: true })
      )
      (map-delete escrow-funds { project-id: project-id })
      (ok true)
    )
  )
)

(define-public (list-credit-for-sale (credit-id uint) (price uint))
  (let
    ((credit (unwrap! (map-get? carbon-credits { credit-id: credit-id }) ERR_NOT_FOUND))
     (retirement-status (unwrap! (map-get? credit-retirement-status { credit-id: credit-id }) ERR_NOT_FOUND)))
    (begin
      (asserts! (is-eq tx-sender (unwrap! (nft-get-owner? carbon-credit credit-id) ERR_NOT_FOUND)) ERR_NOT_AUTHORIZED)
      (asserts! (get verified credit) ERR_NOT_VERIFIED)
      (asserts! (not (get retired retirement-status)) ERR_ALREADY_RETIRED)
      (asserts! (> price u0) ERR_INVALID_PRICE)
      (map-set carbon-credits
        { credit-id: credit-id }
        (merge credit { price: price, for-sale: true })
      )
      (map-set marketplace-listings
        { credit-id: credit-id }
        { seller: tx-sender, price: price, active: true }
      )
      (ok true)
    )
  )
)

(define-public (buy-carbon-credit (credit-id uint))
  (let
    ((credit (unwrap! (map-get? carbon-credits { credit-id: credit-id }) ERR_NOT_FOUND))
     (listing (unwrap! (map-get? marketplace-listings { credit-id: credit-id }) ERR_NOT_FOUND))
     (retirement-status (unwrap! (map-get? credit-retirement-status { credit-id: credit-id }) ERR_NOT_FOUND))
     (seller (get seller listing))
     (price (get price listing)))
    (begin
      (asserts! (get for-sale credit) ERR_NOT_FOUND)
      (asserts! (get active listing) ERR_NOT_FOUND)
      (asserts! (get verified credit) ERR_NOT_VERIFIED)
      (asserts! (not (get retired retirement-status)) ERR_ALREADY_RETIRED)
      (try! (stx-transfer? price tx-sender seller))
      (try! (nft-transfer? carbon-credit credit-id seller tx-sender))
      (map-set carbon-credits
        { credit-id: credit-id }
        (merge credit { for-sale: false })
      )
      (map-set marketplace-listings
        { credit-id: credit-id }
        (merge listing { active: false })
      )
      (ok true)
    )
  )
)

(define-public (retire-carbon-credit (credit-id uint) (retirement-reason (string-ascii 100)))
  (let
    ((credit (unwrap! (map-get? carbon-credits { credit-id: credit-id }) ERR_NOT_FOUND))
     (retirement-status (unwrap! (map-get? credit-retirement-status { credit-id: credit-id }) ERR_NOT_FOUND))
     (owner (unwrap! (nft-get-owner? carbon-credit credit-id) ERR_NOT_FOUND))
     (retirement-id (+ (var-get retirement-id-nonce) u1)))
    (begin
      (asserts! (is-eq tx-sender owner) ERR_NOT_AUTHORIZED)
      (asserts! (get verified credit) ERR_NOT_VERIFIED)
      (asserts! (not (get retired retirement-status)) ERR_ALREADY_RETIRED)
      (var-set retirement-id-nonce retirement-id)
      (try! (nft-burn? carbon-credit credit-id owner))
      (map-set retired-credits
        { retirement-id: retirement-id }
        {
          credit-id: credit-id,
          original-owner: (get creator credit),
          retired-by: tx-sender,
          carbon-amount: (get carbon-amount credit),
          retirement-reason: retirement-reason,
          retired-at: stacks-block-height
        }
      )
      (map-set credit-retirement-status
        { credit-id: credit-id }
        { retired: true, retirement-id: (some retirement-id) }
      )
      (map-set carbon-credits
        { credit-id: credit-id }
        (merge credit { for-sale: false })
      )
      (map-delete marketplace-listings { credit-id: credit-id })
      (ok retirement-id)
    )
  )
)

(define-read-only (get-project (project-id uint))
  (map-get? projects { project-id: project-id })
)

(define-read-only (get-carbon-credit (credit-id uint))
  (map-get? carbon-credits { credit-id: credit-id })
)

(define-read-only (get-project-votes (project-id uint))
  (map-get? project-vote-counts { project-id: project-id })
)

(define-read-only (is-auditor (auditor principal))
  (default-to false (get approved (map-get? auditors { auditor: auditor })))
)

(define-read-only (get-marketplace-listing (credit-id uint))
  (map-get? marketplace-listings { credit-id: credit-id })
)

(define-read-only (get-escrow (project-id uint))
  (map-get? escrow-funds { project-id: project-id })
)

(define-read-only (get-retirement-details (retirement-id uint))
  (map-get? retired-credits { retirement-id: retirement-id })
)

(define-read-only (is-credit-retired (credit-id uint))
  (default-to false (get retired (map-get? credit-retirement-status { credit-id: credit-id })))
)

(define-read-only (get-retirement-status (credit-id uint))
  (map-get? credit-retirement-status { credit-id: credit-id })
)

(define-public (update-credit-price (credit-id uint) (new-price uint))
  (let
    ((credit (unwrap! (map-get? carbon-credits { credit-id: credit-id }) ERR_NOT_FOUND)))
    (begin
      (asserts! (is-eq tx-sender (get creator credit)) ERR_NOT_AUTHORIZED)
      (asserts! (not (get for-sale credit)) ERR_NOT_AUTHORIZED)
      (asserts! (> new-price u0) ERR_INVALID_PRICE)
      (map-set carbon-credits
        { credit-id: credit-id }
        (merge credit { price: new-price })
      )
      (ok true)
    )
  )
)
