effect gradient

layer l {
    let xt = cos(x) * 0.5 + 0.5
    let yt = cos(y) * 0.5 + 0.5
    let at = sin(x * y) * 0.5 + 0.5
    blend rgba(xt, yt, xt, at)
}

emit