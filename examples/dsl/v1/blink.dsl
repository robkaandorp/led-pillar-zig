effect blink

layer l {
    let r = (sin(time * 11 + -x + y / 2) + 1) / 2
    let g = (sin(time * 13 + -x + y / 2.2) + 1) / 2
    let b = (sin(time * 17 + x + y / 2.4) + 1) / 2
    let a = sqrt((sin(-time * 2 + x / 5 + y / 2) + 1) / 2)

    blend rgba(r, g, b, a)
}

emit