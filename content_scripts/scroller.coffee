#
# activatedElement is different from document.activeElement -- the latter seems to be reserved mostly for
# input elements. This mechanism allows us to decide whether to scroll a div or to scroll the whole document.
#
activatedElement = null
settings = null

scrollProperties =
  x: {
    axisName: 'scrollLeft'
    max: 'scrollWidth'
    viewSize: 'clientHeight'
  }
  y: {
    axisName: 'scrollTop'
    max: 'scrollHeight'
    viewSize: 'clientWidth'
  }

getDimension = (el, direction, amount) ->
  if Utils.isString amount
    name = amount
    # the clientSizes of the body are the dimensions of the entire page, but the viewport should only be the
    # part visible through the window
    if name is 'viewSize' and el is document.body
      if direction is 'x' then window.innerWidth else window.innerHeight
    else
      el[scrollProperties[direction][name]]
  else
    amount

# Perform a scroll. Return true if we successfully scrolled by the requested amount, and false otherwise.
performScroll = (element, axisName, amount) ->
  before = element[axisName]
  element[axisName] += amount
  amount == element[axisName] - before

# Test whether element should be scrolled.
shouldScroll = (element, direction) ->
  computedStyle = window.getComputedStyle(element)
  # Elements with `overflow: hidden` should not be scrolled.
  return false if computedStyle.getPropertyValue("overflow-#{direction}") == "hidden"
  # Non-visible elements should not be scrolled.
  return false if computedStyle.getPropertyValue("visibility") in ["hidden", "collapse"]
  return false if computedStyle.getPropertyValue("display") == "none"
  true

# Test whether element actually scrolls in the direction required when asked to do so.  Due to chrome bug
# 110149, scrollHeight and clientHeight cannot be used to reliably determine whether an element will scroll.
# Instead, we scroll the element by 1 or -1 and see if it moved (then put it back).
# Bug verified in Chrome 38.0.2125.104.
isScrollPossible = (element, direction, amount, factor) ->
  axisName = scrollProperties[direction].axisName
  # amount, here, is treated as a relative amount, which is correct for relative scrolls. For absolute scrolls
  # (only gg, G, and friends), amount can be either 'max' or zero. In the former case, we're definitely
  # scrolling forwards, so any positive value will do for delta.  In the latter case, we're definitely
  # scrolling backwards, so a delta of -1 will do.
  delta = factor * getDimension(element, direction, amount) || -1
  delta = delta / Math.abs delta # 1 or -1
  performScroll(element, axisName, delta) and performScroll(element, axisName, -delta)

# Find the element which we should and can scroll (or document.body).
findScrollableElement = (element, direction, amount, factor = 1) ->
  axisName = scrollProperties[direction].axisName
  while element != document.body and
    not (isScrollPossible(element, direction, amount, factor) and shouldScroll(element, direction))
      element = element.parentElement || document.body
  element

checkVisibility = (element) ->
  # if the activated element has been scrolled completely offscreen, subsequent changes in its scroll
  # position will not provide any more visual feedback to the user. therefore we deactivate it so that
  # subsequent scrolls only move the parent element.
  rect = activatedElement.getBoundingClientRect()
  if (rect.bottom < 0 || rect.top > window.innerHeight || rect.right < 0 || rect.left > window.innerWidth)
    activatedElement = element

# How scrolling is handled:
#   - For non-smooth scrolling, the entire scroll happens immediately.
#   - For smooth scrolling with distinct key presses, a separate animator is initiated for each key press.
#     Therefore, several animators may be active at the same time.  This ensures that two quick taps on `j`
#     scroll to the same position as two slower taps.
#   - For smooth scrolling with keyboard repeat (continuous scrolling), the most recently-activated animator
#     continues scrolling at least until its corresponding keyup event is received.  We never initiate a new
#     animator on keyboard repeat.

# Scroll by a relative amount (a number) in some direction, possibly smoothly.
doScrollBy = do ->
  # This is logical time. Time is advanced each time an animator is activated, and on each keyup event.
  time = 0
  mostRecentActivationTime = -1
  lastEvent = null
  keyHandler = null

  (element, direction, amount) ->
    return unless amount

    unless keyHandler
      keyHandler = handlerStack.push
        keydown: -> lastEvent = event
        keyup: -> time += 1

    axisName = scrollProperties[direction].axisName

    unless settings.get "smoothScroll"
      # Jump scrolling.
      performScroll element, axisName, amount
      checkVisibility element
      return

    if mostRecentActivationTime == time or lastEvent?.repeat
      # Either the most-recently activated animator has not yet received its keyup event (so it's still
      # scrolling), or this is a keyboard repeat (for which we don't initiate a new animator).
      # NOTE(smblott) We need both of these checks because sometimes (perhaps one time in twenty) the last
      # keyboard repeat arrives *after* the corresponding keyup.
      return

    mostRecentActivationTime = activationTime = ++time

    isKeyStillDown = ->
      time == activationTime

    # Store amount's sign and make amount positive; the logic is clearer when amount is positive.
    sign = amount / Math.abs amount
    amount = Math.abs amount

    # Duration in ms. Allow a bit longer for longer scrolls.
    duration = Math.max 100, 20 * Math.log amount

    totalDelta = 0
    totalElapsed = 0.0
    calibration = 1.0
    previousTimestamp = null
    animatorId = null

    advanceAnimation = ->
      animatorId = requestAnimationFrame animate

    cancelAnimation = ->
      cancelAnimationFrame animatorId

    animate = (timestamp) ->
      previousTimestamp ?= timestamp

      if timestamp == previousTimestamp
        return advanceAnimation()

      # The elapsed time is typically about 16ms.
      elapsed = timestamp - previousTimestamp
      totalElapsed += elapsed
      previousTimestamp = timestamp

      # The constants in the duration calculation, above, are chosen to provide reasonable scroll speeds for
      # scrolls resulting from distinct keypresses.  For continuous scrolls (where the key remains depressed),
      # some scrolls are too slow, and others too fast.  Here, we compensate a bit.
      if isKeyStillDown() and 50 <= totalElapsed and 0.5 <= calibration <= 1.6
        calibration *= 1.05 if 1.05 * calibration * amount <= 150 # Speed up slow scrolls.
        calibration *= 0.95 if 150 <= 0.95 * calibration * amount # Slow down fast scrolls.

      # Calculate the initial delta, rounding up to ensure progress.  Then, adjust delta to account for the
      # current scroll state.
      delta = Math.ceil amount * (elapsed / duration) * calibration
      delta = if isKeyStillDown() then delta else Math.max 0, Math.min delta, amount - totalDelta

      if delta and performScroll element, axisName, sign * delta
        totalDelta += delta
        advanceAnimation()
      else
        checkVisibility element
        cancelAnimationFrame animatorId

    advanceAnimation()

Scroller =
  init: (frontendSettings) ->
    settings = frontendSettings
    handlerStack.push DOMActivate: -> activatedElement = event.target

  # scroll the active element in :direction by :amount * :factor.
  # :factor is needed because :amount can take on string values, which scrollBy converts to element dimensions.
  scrollBy: (direction, amount, factor = 1) ->
    # if this is called before domReady, just use the window scroll function
    if (!document.body and amount instanceof Number)
      if (direction == "x")
        window.scrollBy(amount, 0)
      else
        window.scrollBy(0, amount)
      return

    activatedElement ||= document.body
    return unless activatedElement

    element = findScrollableElement activatedElement, direction, amount, factor
    elementAmount = factor * getDimension element, direction, amount
    doScrollBy element, direction, elementAmount

  scrollTo: (direction, pos) ->
    return unless document.body or activatedElement
    activatedElement ||= document.body

    element = findScrollableElement activatedElement, direction, pos
    amount = getDimension(element,direction,pos) - element[scrollProperties[direction].axisName]
    doScrollBy element, direction, amount

root = exports ? window
root.Scroller = Scroller
